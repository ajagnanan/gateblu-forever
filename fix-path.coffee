path = require 'path'

module.exports = (thePath) =>
  if thePath.indexOf('/Library/Application') == 0
    home = process.env.HOME
    return path.join home, thePath 
  return thePath
