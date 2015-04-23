util = require('util')
{EventEmitter} = require('events')
fs = require('fs-extra')
path = require('path')
forever = require('forever-monitor')
exec = require('child_process').exec
_ = require('lodash')
async = require('async')
request = require('request')
debug = require('debug')('gateblu:deviceManager')

class DeviceManager extends EventEmitter
  constructor: (@config) ->
      @deviceProcesses = {}
      @runningDevices = []

  refreshDevices: (devices, callback) =>
    debug 'refreshDevices', _.pluck(devices, 'uuid')

    @getDeviceOperations devices, @runningDevices, (devicesToStart, devicesToStop, devicesToRestart, unchangedDevices) =>
      connectorsToInstall = _.uniq _.pluck devicesToStart, 'connector'

      async.series(
        [
          (callback) => async.eachSeries connectorsToInstall, @installConnector, callback
          (callback) => async.each devicesToStop, @stopDevice, callback
          (callback) => async.eachSeries devicesToStart, @setupDevice, callback
          (callback) => async.eachSeries devicesToStart, @startDevice, callback
          (callback) => async.each devicesToRestart, @restartDevice, callback
        ]
        (error, result)=>
          @runningDevices = _.union devicesToStart, devicesToRestart
          @emit 'update', _.union(devicesToStart, devicesToRestart, devicesToStop, unchangedDevices)
          callback error, result
      )

  getDeviceOperations: (newDevices=[], oldDevices=[], callback=->) =>
    debug 'getDeviceOperations'
    debug 'newDevices', _.pluck(newDevices, 'name')
    debug 'oldDevices', _.pluck(oldDevices, 'name')

    devicesToProcess = _.clone newDevices
    async.map devicesToProcess, @deviceExists, (error, remainingDevices) =>
      return callback error if error?
      remainingDevices = _.compact remainingDevices
      debug 'devices that exist', _.pluck(remainingDevices, 'name')

      devicesToStop = _.filter remainingDevices, stop: true
      debug 'devicesToStop:', _.pluck(devicesToStop, 'name')
      remainingDevices = _.difference remainingDevices, devicesToStop

      devicesToStart = _.reject remainingDevices, (device) =>
        _.findWhere oldDevices, uuid: device.uuid

      debug 'devicesToStart:', _.pluck(devicesToStart, 'name')

      remainingDevices = _.difference remainingDevices, devicesToStart

      devicesToRestart = _.filter remainingDevices, (device) =>
        deviceToRestart =_.findWhere oldDevices, uuid: device.uuid
        return deviceToRestart?.token != device.token

      debug 'devicesToRestart:', _.pluck(devicesToRestart, 'name')

      unchangedDevices = _.difference remainingDevices, devicesToRestart
      debug 'unchangedDevices', _.pluck(unchangedDevices, 'name')

      callback devicesToStart, devicesToStop, devicesToRestart, unchangedDevices

  deviceExists: (device, callback=->) =>
    debug 'deviceExists', device.uuid

    authHeaders =
      skynet_auth_uuid: device.uuid
      skynet_auth_token: device.token
    deviceUrl = "http://#{@config.server}:#{@config.port}/devices/#{device.uuid}"
    debug 'requesting device', deviceUrl, 'auth:', authHeaders

    request url: deviceUrl, headers: authHeaders, json: true, (error, response, body) =>
      debug "deviceExists response:", body
      return callback(error, null) if error? || body.error?
      device = _.extend {}, body.devices[0], device
      debug 'device exists', device.name
      callback null, device

  startDevice : (device, callback=->) =>
    debug 'startDevice', { name: device.name, uuid: device.uuid}
    devicePath = path.join @config.devicePath, device.uuid
    @writeMeshbluJSON devicePath, device

    pathSep = ':'
    pathSep = ';' if process.platform == 'win32'

    foreverOptions =
      max: 1
      silent: true
      options: []
      cwd: devicePath
      logFile: devicePath + '/forever.log'
      outFile: devicePath + '/forever.stdout'
      errFile: devicePath + '/forever.stderr'
      command: 'node'
      checkFile: false

    child = new (forever.Monitor)('command.js', foreverOptions)
    child.on 'stderr', (data) =>
      debug 'stderr', device.uuid, data.toString()
      @emit 'stderr', data.toString(), device

    child.on 'stdout', (data) =>
      debug 'stdout', device.uuid, data.toString()
      @emit 'stdout', data.toString(), device

    debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
    child.start()
    @deviceProcesses[device.uuid] = child
    @emit 'start', device
    callback()

  installConnector : (connector, callback=->) =>
    debug 'installConnector', connector
    nodeModulesDir = path.join @config.tmpPath, 'node_modules'
    fs.mkdirpSync nodeModulesDir
    connectorPath = path.join nodeModulesDir, connector
    if fs.existsSync connectorPath
      debug "connector #{connector} already installed. skipping installation"
      return callback()

    prefix = ''
    prefix = 'cmd.exe /c ' if process.platform == 'win32'

    exec("#{prefix} npm --prefix=. install #{connector}"
      cwd: @config.tmpPath
      (error, stdout, stderr) =>
        if error?
          debug 'forever error:', error
          console.error error
          @emit 'stderr', error
          return callback()

        @emit 'npm:stderr', stderr.toString()
        @emit 'npm:stdout', stdout.toString()
        debug 'forever stdout', stdout.toString()
        debug 'forever stderr', stderr.toString()
        callback()
    )

  setupDevice: (device, callback) =>
    debug 'setupDevice', {uuid: device.uuid, name: device.name}

    devicePath = path.join @config.devicePath, device.uuid
    connectorPath = path.join @config.tmpPath, 'node_modules', device.connector

    debug 'path', devicePath
    debug 'connectorPath', connectorPath

    try
      debug 'copying files', devicePath
      fs.removeSync devicePath
      fs.copySync connectorPath, devicePath
      _.defer => callback()

    catch error
      console.error error
      @emit 'stderr', error
      debug 'forever error:', error
      _.defer => callback()

  writeMeshbluJSON: (devicePath, device) =>
    meshbluFilename = path.join(devicePath, 'meshblu.json')
    deviceConfig = _.extend {}, device, {server: @config.server, port: @config.port}
    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing meshblu.json', devicePath
    fs.writeFileSync meshbluFilename, meshbluConfig

  restartDevice: (device, callback) =>
    debug 'restartDevice', {uuid: device.uuid, name: device.name}
    @stopDevice device, (error) =>
      debug 'restartDevice error:', error if error?
      @startDevice device, callback

  stopDevice : (device, callback=->) =>
    debug 'stopDevice', device.uuid
    deviceProcess = @deviceProcesses[device.uuid]
    return callback null, device.uuid unless deviceProcess?

    deviceProcess.on 'stop', =>
      debug "process for #{device.uuid} stopped."
      delete @deviceProcesses[device.uuid]
      callback null, device

    if deviceProcess.running
      debug 'killing process for', device.uuid
      deviceProcess.killSignal = 'SIGINT'
      deviceProcess.kill()
      return

    debug 'process for ' + uuid + ' wasn\'t running. Removing record.'
    delete @deviceProcesses[uuid]
    callback null, uuid

  stopDevices: (callback=->) =>
    async.eachSeries @runningDevices, @stopDevice, callback

module.exports = DeviceManager
