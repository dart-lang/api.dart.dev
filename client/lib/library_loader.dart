library library_loader;

import 'ast.dart';

int rateLimit = 2;
Set<String> _requested = new Set<String>();
Set<String> _pending = new Set<String>();
Set<String> _loaded = new Set<String>();

// TODO(jacobr): change to a queue.
List<String> queuedLibraries = <String>[];

/** Users must inject their own prefered library loader. */
Function libraryLoader;
Function onDataModelChanged;

/** High priority request, load immediately. */
bool load(String libraryName) {
  // Can't load if the package manifest isn't even loaded yet.
  if (package == null) {
    return queue(libraryName);
  }

  if (_pending.contains(libraryName) ||
      _loaded.contains(libraryName)) return false;
  _requested.add(libraryName);
  _pending.add(libraryName);
  // TODO(jacobr): check whether the library is really in this package
  // not one of its dependencies.
  // TODO(jacobr): we don't handle the case where packages with the same
  // name are defined in multiple locations. Names really need to list their
  // package.

  // TODO(jacobr): don't hard code static/data.
  var rootDir = '../static/data';
  if (package.location != null) rootDir = '$rootDir/${package.location}';
  libraryLoader('$rootDir/$libraryName.json', (json) {
   _onLibraryLoaded(libraryName, json);
  });

  return true;
}

/** Low priority request, add it to the queue of libraries to load. */
bool queue(String libraryName) {
  if (_requested.contains(libraryName)) return false;
  _requested.add(libraryName);
  queuedLibraries.add(libraryName);
  if (package != null && _pending.isEmpty) {
    _loadNext();
  }
  return true;
}

void _onLibraryLoaded(String libraryName, String json) {
  _loaded.add(libraryName);
  _pending.remove(libraryName);
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
    String next = queuedLibraries.removeAt(0);
    if (load(next)) break;
  }
}