// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * This is a helper for run.sh. We try to run all of the Dart code in one
 * instance of the Dart VM to reduce warm-up time.
 */
library run_impl;

import 'dart:async';
import 'dart:io';
import 'dart:utf' show encodeUtf8;
import 'dart:isolate';
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';
import 'package:web_ui/dwc.dart' as dwc;

import 'ast_test.dart' as ast_test;

// TODO(jacobr): command line args to filter tests
main() {
  var args = new Options().arguments;
  var pattern = new RegExp(args.length > 0 ? args[0] : '.');

  useCompactVMConfiguration();

  void addGroup(testFile, testMain) {
    if (pattern.hasMatch(testFile)) {
      group(testFile.replaceAll('_test.dart', ':'), testMain);
    }
  }

  addGroup('ast_test.dart', ast_test.main);

  // TODO(jacobr): should have listSync for scripting...
  var lister = new Directory.fromPath(new Path('data/input')).list();
  var cwd = new Path(new Directory.current().path);
  var inputDir = cwd.append('data/input');
  lister.onFile = (path) {
    if (!path.endsWith('_test.html') || !pattern.hasMatch(path)) return;
    var filename = new Path(path).filename;

    test('drt-compile $filename', () {
      expect(dwc.run(['-o', 'data/output/', path], printTime: false)
        .then((res) {
          expect(res.messages.length, 0,
              reason: '${res.messages}\n');
        }), completes);
    });

    test('drt-run $filename', () {
      var outDir = cwd.append('data').append('output');
      var htmlPath = outDir.append(filename).toString();
      var outputPath = '$htmlPath.txt';
      var errorPath = outDir.append('_errors.$filename.txt').toString();

      expect(_runDrt(htmlPath, outputPath, errorPath).then((exitCode) {
        if (exitCode == 0) {
          var expectedPath = '$cwd/data/expected/$filename.txt';
          expect(_diff(expectedPath, outputPath).then((res) {
              expect(res, 0, reason: "Test output doesn't match expectation.");
            }), completes);
        } else {
          expect(Process.run('cat', [errorPath]).then((res) {
            expect(exitCode, 0, reason:
              'DumpRenderTree exited with a non-zero exit code, when running '
              'on $filename. Contents of stderr: \n${res.stdout}');
          }), completes);
        }
      }), completes);
    });
  };
}

Future<int> _runDrt(htmlPath, String outPath, String errPath) {
  return Process.run('DumpRenderTree', [htmlPath]).then((res) {
    var f1 = _writeFile(outPath, res.stdout);
    var f2 = _writeFile(errPath, res.stderr);
    return Future.wait([f1, f2]).then((_) => res.exitCode);
  });
}

Future _writeFile(String path, String text) {
  return new File(path).open(FileMode.WRITE)
      .then((file) => file.writeString(text))
      .then((file) => file.close());
}

Future<int> _diff(expectedPath, outputPath) {
  return Process.run('diff', ['-q', expectedPath, outputPath])
      .then((res) => res.exitCode);
}
