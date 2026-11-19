const { add } = require('./util')
const lib = require('./lib')

function useAll() {
  return add(1, 2) + lib.helper()
}

exports.useAll = useAll
