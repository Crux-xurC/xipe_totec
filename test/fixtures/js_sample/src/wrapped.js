(function (root) {
  'use strict';
  var App = (root.App = root.App || {});

  function load(name) {
    return parse(name)
  }

  function parse(text) {
    return text.trim()
  }

  var helper = function (x) { return load(x) };

  App.loader = { load: load };
})(this);
