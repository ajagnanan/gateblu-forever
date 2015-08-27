{EventEmitter} = require 'events'
DeviceManager = require '../index'

describe 'DeviceManager', ->
  beforeEach ->
    @sut = new DeviceManager {}

  describe 'addDevice', ->
    beforeEach ->
      @sut.installConnector = sinon.stub().yields null
      @sut.setupDevice = sinon.stub().yields null
      @sut.startDevice = sinon.stub().yields null
      @sut.addDevice uuid: '1234', connector: 'meshblu:something'

    it 'should call installConnector', ->
      expect(@sut.installConnector).to.have.been.calledWith 'meshblu:something'

    it 'should do log things', ->
      expect('not logging').to.equals('logging')
