// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/** Manages loading library models from the server. */
library library_loader;

import 'ast.dart';

/** Target number of simultaneous connections. */
int rateLimit = 2;

final _requested = new Set<Reference>();
final _pending = new Set<Reference>();
final _loaded = new Set<Reference>();

// TODO(jacobr): change to a queue.
final queuedLibraries = <Reference>[];

/** Users must inject their own prefered library loader. */
Function libraryLoader;
Function onDataModelChanged;

/** High priority request, load immediately. */
bool load(Reference libraryRef) {
  // Can't load if the package manifest isn't even loaded yet.
  if (package == null) return queue(libraryRef);

  if (_pending.contains(libraryRef) ||
      _loaded.contains(libraryRef)) return false;
  _requested.add(libraryRef);
  _pending.add(libraryRef);
  // TODO(jacobr): check whether the library is really in this package
  // not one of its dependencies.
  // TODO(jacobr): we don't handle the case where packages with the same
  // name are defined in multiple locations. Names really need to list their
  // package.

  // TODO(jacobr): don't hard code.
  var rootDir = '../../data';
  if (package.location != null) rootDir = '$rootDir/${package.location}';
  libraryLoader('$rootDir/${libraryRef.refId}.json', (json) {
   _onLibraryLoaded(libraryRef, json);
  });

  return true;
}

/** Low priority request, add it to the queue of libraries to load. */
bool queue(Reference libraryRef) {
  if (_requested.contains(libraryRef)) return false;
  _requested.add(libraryRef);
  queuedLibraries.add(libraryRef);
  if (package != null && _pending.isEmpty) {
    _loadNext();
  }
  return true;
}

void _onLibraryLoaded(Reference libraryRef, String json) {
  _loaded.add(libraryRef);
  _pending.remove(libraryRef);
  // TODO(jacobr): add try/catch block here.
  if (json != null) {
    loadLibraryJson(json);
  }
  _loadNext();
  onDataModelChanged();
}

void _loadNext() {
  // We may be above the rate limit if load requests are forced while there are
  // already pending regular requests.
  if (_pending.length >= rateLimit) return;

  while (!queuedLibraries.isEmpty) {
    Reference next = queuedLibraries.removeAt(0);
    if (load(next)) break;
  }
}