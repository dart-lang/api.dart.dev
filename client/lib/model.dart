// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library apidoc_model;

import 'dart:async';
import 'dart:html' as html;
import 'dart:json' as json;
import 'package:web_ui/watcher.dart' as watchers;
import 'package:web_ui/safe_html.dart';
import 'package:poppy/trie.dart';
import 'markdown.dart' as md;
import 'ast.dart';
import 'library_loader.dart' as library_loader;

// TODO(jacobr): specify the version # in the JSON file.
String svnRevisionNumber = "15605";

/** Whether to show private members. */
bool showPrivate = true;
/** Whether to show inherited members. */
bool showInherited = true;

/**
 * Reference id of [currentElement].
 *
 * Stored in addition to [currentElement] as [currentElement] may
 * not yet be available if the data model for the library it is part of has
 * not yet been loaded.
 */
String _currentReferenceId;

/**
 * Current library the user is browsing if any.
 */
LibraryElement currentLibrary;

/**
 * Current type the user is viewing if any.
 * Should be either a [ClassElement] or a [TypedefElement].
 */
Element currentType;
/**
 * Current member of either [currentLibrary] or [currentType] that the user is
 * viewing.
 */
Element currentMember;

/**
 * Element corresponding to [_currentReferenceId].
 * The most specific element of [currentLibrary]. [currentType], and
 * [currentMember].
 */
Element currentElement;

/**
 * Set a different element as the element actively rendered by the UI.
 */
void navigateTo(String referenceId) {
  _currentReferenceId = referenceId;
  _recomputeActiveState();
  html.window.history.pushState({},
      currentElement.name,
      permalink(currentElement));
  scrollIntoView();
  watchers.dispatch();
}

/**
 * Recomputes the Elements part of the current active state from the data model.
 *
 * This method should be invoked after additional libraries are loaded from the
 * server or after the user navigates to a different element in the UI.
 */
void _recomputeActiveState() {
  currentLibrary = null;
  currentType = null;
  currentMember = null;
  currentElement = null;
  if (_currentReferenceId != null) {
    var referenceElement = lookupReferenceId(_currentReferenceId);
    if (referenceElement != null) {
      var path = referenceElement.path;
      if (path.length > 0) {
        currentLibrary = path[0];
      }
      if (path.length > 1) {
        if (path[1] is ClassElement || path[1] is TypedefElement) {
          currentType = path[1];
          if (path.length > 2) {
            currentMember = path[2];
          }
        } else {
          currentMember = path[1];
        }
      }
      if (currentMember != null) {
        currentElement = currentMember;
      } else if (currentType != null) {
        currentElement = currentType;
      } else {
        currentElement = currentLibrary;
      }
    }
  }
}

/**
 * Scrolls the [currentElement] into view.
 */
void scrollIntoView() {
  // TODO(jacobr): there should be a cleaner way to run code that executes
  // after the UI updates. https://github.com/dart-lang/web-ui/issues/188
  html.window.setTimeout(() {
    if (currentElement != null) {
      for (var e in html.queryAll('[data-id="${currentElement.id}"]')) {
        e.scrollIntoView(false);
      }
    }
  }, 0);
}

/**
 * Invoke every time the data model changes.
 */
void _onDataModelChanged() {
  _recomputeActiveState();
  scrollIntoView();
  watchers.dispatch();
}

/**
 * Generate a CSS class given an element that may be a class, member, method,
 * etc.
 */
String kindCssClass(Element element) {
  String classes = 'kind kind-${_normalizedKind(element)}';
  if (element.isPrivate == true) {
    classes = '$classes private';
  } else if (element is MethodLikeElement &&
      (element as MethodLikeElement).isStatic) {
    classes = '$classes static';
  }

  // Setters are viewed as methods by the AST.
  if (element is PropertyElement) {
    classes = '$classes getter';
  }

  if (element is MethodLikeElement && (element as MethodLikeElement).isSetter) {
    classes = '$classes setter';
  }

  return classes;
}

String _normalizedKind(Element element) {
  var kind = element.kind;
  var name = element.name;
  if (kind == 'method' && (element as MethodLikeElement).isOperator) {
    kind = 'operator';
  }
  // TODO(jacobr): this is horrible but matches what DartDoc does
  if (kind == 'class' && name.endsWith('Exception')) {
    kind = 'exception';
  }
  return kind;
}

String toUserVisibleKind(Element element) {
  return KIND_TITLES[_normalizedKind(element)];
}

/**
 * Generate a permalink referencing a specific element.
 * [obj] shoudl be a [Reference] or [Element].
 */
String permalink(var obj) {
  var data = {'id': obj.refId};
  if (showPrivate) {
    data['showPrivate'] = showPrivate;
  }

  if (showInherited) {
    data['showInherited'] = showInherited;
  }
  return "#!${json.stringify(data)}";
}

void loadStateFromUrl() {
  String link = html.window.location.hash;
  var data = {};
  if (link.length > 2) {
    try {
      // strip #! and parse json.
      data = json.parse(link.substring(2));
    } catch (e) {
      html.window.console.error("Invalid link url");
      // TODO(jacobr): redirect to default page or better yet attempt to fixup.
    }
  }

  if (data.containsKey('showPrivate')) {
    showPrivate = data['showPrivate'];
  } else {
    showPrivate = false;
  }
  if (data.containsKey('showInherited')) {
    showInherited = data['showInherited'];
  } else {
    showInherited = false;
  }

  _currentReferenceId = data['id'];
  _recomputeActiveState();
  scrollIntoView();
}

Future loadModel() {
  // Note: listen on both popState and hashChange, because IE9 doens't support
  // history API, and it doesn't work properly on Opera 12.
  // See http://dartbug.com/5483
  updateState(e) {
    loadStateFromUrl();
    watchers.dispatch();
  }
  html.window.on
    ..popState.add(updateState)
    ..hashChange.add(updateState);

  // Patch in support for [:...:]-style code to the markdown parser.
  // TODO(rnystrom): Markdown already has syntax for this. Phase this out?
  md.InlineParser.syntaxes.insertRange(0, 1,
      new md.CodeSyntax(r'\[\:((?:.|\n)*?)\:\]'));

  md.setImplicitLinkResolver(_resolveNameReference);
  var completer = new Completer();
  library_loader.libraryLoader = (url, callback) {
    new html.HttpRequest.get(url, (req) {
      callback(req.responseText);
    });
  };
  library_loader.onDataModelChanged = _onDataModelChanged;

  // TODO(jacobr): shouldn't have to get this from the parent directory.
  new html.HttpRequest.get('../static/data/apidoc.json', (req) {
    loadPackageJson(req.responseText);
    _onDataModelChanged();
    completer.complete(true);
  });
  return completer.future;
}

// TODO(jacobr): remove this method and resolve refences to types in the json
// generation. That way the existing correct logic in Dart2Js can be used rather
// than this rather busted logic.
/**
 * This will be called whenever a doc comment hits a `[name]` in square
 * brackets. It will try to figure out what the name refers to and link or
 * style it appropriately.
 */
md.MarkdownNode _resolveNameReference(String name) {
  // TODO(jacobr): this isn't right yet and we have made this code quite ugly
  // by using the verbose universal permalink member even though library is
  // always currentLibrary.
  makeLink(String href) {
    return new md.MarkdownElement.text('a', name)
      ..attributes['href'] = href
      ..attributes['class'] = 'crossref';
  }

  // See if it's a parameter of the current method.
  if (currentMember != null && currentMember.kind == 'method') {
    var parameters = currentMember.children;
    for (final parameter in parameters) {
      if (parameter.name == name) {
        final element = new md.MarkdownElement.text('span', name);
        element.attributes['class'] = 'param';
        return element;
      }
    }
  }

  // See if it's another member of the current type.
  // TODO(jacobr): fixme. this is wrong... members are by id now not simple
  // string name...
  if (currentType != null) {
    // TODO(jacobr): this should be foundMember = currentType.members[name];
    final foundMember = null;
    if (foundMember != null) {
      return makeLink(permalink(foundMember));
    }
  }

  // See if it's another type or a member of another type in the current
  // library.
  if (currentLibrary != null) {
    // See if it's a constructor
    final constructorLink = (() {
      final match =
          new RegExp(r'new ([\w$]+)(?:\.([\w$]+))?').firstMatch(name);
      if (match == null) return null;
      String typeName = match[1];
      var foundType = currentLibrary.classes[typeName];
      if (foundType == null) return null;
      String constructorName =
          (match[2] == null) ? typeName : '$typeName.${match[2]}';
          final constructor =
              foundType.constructors[constructorName];
          if (constructor == null) return null;
          return makeLink(permalink(constructor));
    })();
    if (constructorLink != null) return constructorLink;

    // See if it's a member of another type
    final foreignMemberLink = (() {
      final match = new RegExp(r'([\w$]+)\.([\w$]+)').firstMatch(name);
      if (match == null) return null;
      var foundType = currentLibrary.classes[match[1]];
      if (foundType == null) return null;
      // TODO(jacobr): should be foundMember = foundType.members[match[2]];
      var foundMember = null;
      if (foundMember == null) return null;
      return makeLink(permalink(foundMember));
    })();
    if (foreignMemberLink != null) return foreignMemberLink;

    var foundType = currentLibrary.classes[name];
    if (foundType != null) {
      return makeLink(permalink(foundType));
    }

    // See if it's a top-level member in the current library.
    // TODO(jacobr): should be foundMember = currentLibrary.members[name];
    var foundMember = null;
    if (foundMember != null) {
      return makeLink(permalink(foundMember));
    }
  }

  // TODO(jacobr): Should also consider:
  // * Names imported by libraries this library imports. Don't think we even
  //   store this in the AST.
  // * Type parameters of the enclosing type.

  return new md.MarkdownElement.text('code', name);
}

/**
 * Search Result matching an node in the AST.
 */
class SearchResult implements Comparable {
  /** [Element] this search result references. */
  Element element;
  /** Score of the search result match. Higher is better. */
  num score;

  /**
   * Order results with higher scores before lower scores.
   * */
  int compareTo(SearchResult other) => other.score.compareTo(score);

  SearchResult(this.element, this.score);
}

final indexedLibraries = new Set<LibraryElement>();
final searchIndex = new SimpleTrie<List<Element>>();

void _indexLibrary(LibraryElement library) {
  library.traverse((Element element) {
    addEntry(name) {
      var id = name;
      var existing = searchIndex[id];
      if (existing == null ) {
        searchIndex[id] = <Element>[element];
      } else {
        existing.add(element);
      }
    }
    var name = element.name;
    var nameLowerCase = name.toLowerCase();
    addEntry(nameLowerCase);
    // TODO(jacobr): if name has underscores in the middle, word break
    // differently.

    // Add all suffixes of the name that begin with a capital letter.
    var initials = new StringBuffer();
    for (int i = 0; i < name.length; i++) {
      int code = name.charCodeAt(i);
      // Upper case character or number.
      if ((code >= 65 && code <= 90) || (code >= 48 && code <= 57)) {
        if (i > 0) {
          addEntry(nameLowerCase.substring(i));
        }
        initials.addCharCode(nameLowerCase.charCodeAt(i));
      }
    }
    if (initials.length > 1) {
      addEntry(initials.toString());
    }
    // Only continue traversing for Class and Library elements.
    return element is ClassElement || element is LibraryElement;
  });
}

List<SearchResult> lookupSearchResults(String query, int maxResults) {
  // TODO(jacobr): use a heap rather than a list.
  var results = <SearchResult>[];
  if (query.isEmpty) return results;
  for (var library in libraries.values) {
    if (!indexedLibraries.contains(library)) {
      indexedLibraries.add(library);
      _indexLibrary(library);
    }
  }
  query = query.toLowerCase();
  var resultSet = new Set<Element>();
  for (var elements in searchIndex.getValuesWithPrefix(query)) {
    for (var element in elements) {
      if (!resultSet.contains(element)) {
        // It is possible for the same prefix to match multiple ways.
        resultSet.add(element);
        var name = element.name.toLowerCase();
        // Trivial formula penalizing matches that start later in the string
        // breaking ties with the length of the name.
        // TODO(jacobr): this formula is primitive. We should order by popularity
        // and the number of words into the match instead.
        // Also prioritize base classes over subclasses when sorting(?)
        num score = -name.indexOf(query) - element.name.length * 0.001;
        if (element is LibraryElement) score += 1000;
        if (element is ClassElement) score += 100;
        results.add(new SearchResult(element, score));
      }
    }
  }
  results.sort();
  // TODO(jacobr): sort and filter down to max results, remove dupes etc.
  if (results.length > maxResults) {
    // TODO(jacobr): ugly way to do this.
    results.removeRange(maxResults, results.length - maxResults);
  }
  return results;
}