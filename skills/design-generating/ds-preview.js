// ds-preview.js — render design-system components straight from their .jsx/.tsx
// source in a browser, with no build step. Copy it to the design system root as
// _ds_preview.js; component cards and UI kits load it after React, ReactDOM and
// @babel/standalone:
//
//   DS.load('./Button.jsx').then(({ Button }) => { ... })
//   DS.mount('#root', { Button: './Button.jsx' }, (c) => <c.Button>Save</c.Button>)
//
// Serve the directory over http (e.g. `python -m http.server`): browsers block
// fetch() on file:// pages.
//
// Each module is transpiled (JSX, TypeScript, ES modules -> CommonJS), its
// relative imports are loaded first, then it runs with a require() that knows
// react, react-dom, and those siblings. A `.css` import becomes a <link>.
// Import cycles are not supported.
(function (global) {
  'use strict';

  var EXTENSIONS = ['.jsx', '.tsx', '.js', '.ts'];
  var BARE = {
    react: function () { return global.React; },
    'react-dom': function () { return global.ReactDOM; },
    'react-dom/client': function () { return global.ReactDOM; },
  };
  var pending = {};   // requested URL -> promise of exports
  var resolved = {};  // fetched URL -> promise of exports, so './Button' and
                      // './Button.jsx' share one module instance

  function hasExtension(url) {
    return /\.[a-z]+$/i.test(new URL(url).pathname);
  }

  function fetchSource(url) {
    var candidates = hasExtension(url)
      ? [url]
      : EXTENSIONS.map(function (ext) { return url + ext; })
          .concat(EXTENSIONS.map(function (ext) { return url + '/index' + ext; }));
    var i = 0;
    function next() {
      if (i >= candidates.length) {
        return Promise.reject(new Error('ds-preview: cannot load ' + url));
      }
      var candidate = candidates[i++];
      return fetch(candidate).then(function (res) {
        if (!res.ok) return next();
        return res.text().then(function (code) { return { url: candidate, code: code }; });
      }, next);
    }
    return next();
  }

  function transpile(src) {
    var presets = ['react'];
    if (/\.tsx?$/.test(src.url)) {
      presets.push(['typescript', { isTSX: true, allExtensions: true }]);
    }
    return global.Babel.transform(src.code, {
      filename: src.url,
      presets: presets,
      plugins: ['transform-modules-commonjs'],
      sourceType: 'module',
    }).code;
  }

  function requiredSpecifiers(code) {
    var re = /\brequire\((['"])([^'"]+)\1\)/g;
    var found = [];
    var m;
    while ((m = re.exec(code))) {
      if (found.indexOf(m[2]) === -1) found.push(m[2]);
    }
    return found;
  }

  function linkStylesheet(href) {
    if (!global.document) return;
    if (global.document.querySelector('link[href="' + href + '"]')) return;
    var link = global.document.createElement('link');
    link.rel = 'stylesheet';
    link.href = href;
    global.document.head.appendChild(link);
  }

  function load(path, base) {
    var url = new URL(path, base || global.location.href).href;
    if (!pending[url]) {
      pending[url] = fetchSource(url).then(function (src) {
        if (!resolved[src.url]) resolved[src.url] = evaluate(src);
        return resolved[src.url];
      });
    }
    return pending[url];
  }

  function evaluate(src) {
    var code = transpile(src);
    var deps = {};
    var relative = requiredSpecifiers(code).filter(function (spec) {
      return spec.charAt(0) === '.';
    });
    return Promise.all(relative.map(function (spec) {
      var depUrl = new URL(spec, src.url).href;
      if (/\.css$/i.test(spec)) {
        linkStylesheet(depUrl);
        deps[spec] = {};
        return null;
      }
      return load(depUrl).then(function (exports) { deps[spec] = exports; });
    })).then(function () {
      var module = { exports: {} };
      function require(spec) {
        if (Object.prototype.hasOwnProperty.call(deps, spec)) return deps[spec];
        if (Object.prototype.hasOwnProperty.call(BARE, spec)) return BARE[spec]();
        throw new Error('ds-preview: ' + src.url + ' imports "' + spec +
          '" — components may import React and relative siblings only');
      }
      new Function('require', 'module', 'exports', code)(require, module, module.exports);
      return module.exports;
    });
  }

  // Load a map of { Name: path }, pick each module's export of that name, and
  // render render(components) into the element matched by selector.
  function mount(selector, paths, render) {
    var names = Object.keys(paths);
    return Promise.all(names.map(function (name) { return load(paths[name]); }))
      .then(function (modules) {
        var components = {};
        names.forEach(function (name, i) {
          var mod = modules[i];
          if (!(name in mod)) {
            throw new Error('ds-preview: ' + paths[name] + ' has no export named ' + name);
          }
          components[name] = mod[name];
        });
        var el = typeof selector === 'string'
          ? global.document.querySelector(selector) : selector;
        global.ReactDOM.createRoot(el).render(render(components));
        return components;
      });
  }

  global.DS = { load: load, mount: mount };
})(typeof window !== 'undefined' ? window : globalThis);
