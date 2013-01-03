// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Unittests for the AST describing all information about Dart libraries
 * required to render Dart documentation.
 */
library ast_test;

import 'package:unittest/unittest.dart';
import 'package:api_doc/ast.dart';
import 'compact_vm_config.dart';
import 'dart:io';

main() {
  useCompactVMConfiguration();
  // TODO(jacobr): consider using a smaller testing only JSON file.
  // We only test for the existence of libraries, classes, and members that
  // are extremely unlikely to change so that this test will rarely fail due to
  // Dart API changes.
  loadLibraryJson(new File('../web/static/apidoc.json').readAsStringSync());
  group('Element', () {
    test('lookupReferenceId', () {
      expect(lookupReferenceId('dart:core'), isNotNull);
      expect(lookupReferenceId('dart:core/Object'), isNotNull);
      expect(lookupReferenceId('dart:core/Object/toString0()'), isNotNull);
      expect(lookupReferenceId('dart:core/Object/Object0()'), isNotNull);
      expect(lookupReferenceId('dart:core/Object/==1()'), isNotNull);
      expect(lookupReferenceId('dart:core/FooBarNotAClass'), isNull);
    });

    test('path', () {
      var objElement = lookupReferenceId('dart:core/Object');
      var path = objElement.path;
      expect(path.length, equals(2));
      expect(path[0], equals(lookupReferenceId('dart:core')));
      expect(path[1], equals(objElement));
    });
  });
}
