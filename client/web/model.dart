library apidoc_model;

import 'package:web_ui/watcher.dart' as watchers;
import 'package:web_ui/safe_html.dart';
import 'markdown.dart' as md;
import 'dart:html' as html;
import 'dart:json';
import 'ast.dart';

String svnRevisionNumber = "15605";

String _activeReferenceId;

/// Current state of the application.
LibraryElement currentLibrary;
Element currentType;
Element currentMember;
Element currentElement;

void _recomputeActiveState() {
  currentLibrary = null;
  currentType = null;
  currentMember = null;
  currentElement = null;
  if (_activeReferenceId != null) {
    var path = lookupReferenceId(_activeReferenceId).path;

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

void scrollIntoView() {
  // TODO(jacobr): there should be a cleaner way to run code that executes
  // after the UI updates.
  html.window.setTimeout(() {
    if (currentElement != null) {
      for (var e in html.queryAll('[data-id="${currentElement.id}"]')) {
        e.scrollIntoView(false);
      }
    }
  }, 0);
}

onDataModelChanged() {
  _recomputeActiveState();
  scrollIntoView();
}

/**
 * Generate a CSS class given an element that may be a class, member, method,
 * etc.
 */
String kindCssClass(Element element) {
  String classes = 'kind kind-${normalizedKind(element)}';
  if (element.isPrivate == true) {
    classes = '$classes private';
  } else if (element is MethodElementBase && element.isStatic) {
    classes = '$classes static';
  }

  // Setters are viewed as methods by the AST.
  if (element is PropertyElement) {
    classes = '$classes getter';
  }

  if (element is MethodElementBase && element.isSetter) {
    classes = '$classes setter';
  }

  return classes;
}

String normalizedKind(obj) {
  if (obj is Element) return normalizedKindFromElement(obj);
  return obj;
}

String normalizedKindFromElement(Element element) {
  var kind = element.kind;
  var name = element.name;
  if (kind == 'method' && element.isOperator) {
    kind = 'operator';
  }
  // TODO(jacobr): this is horrible but matches what DartDoc does
  if (kind == 'class' && name.endsWith('Exception')) {
    kind = 'exception';
  }
  return kind;
}

String toUserVisibleKind(Element element) {
  return KIND_TITLES[normalizedKind(element)];
}

/**
 * [obj] shoudl be a [Reference] or [Element].
 */
String permalink(var obj) {
  var data = {'id': obj.refId};
  return "#!${JSON.stringify(data)}";
}

void loadStateFromUrl() {
  String link = html.window.location.hash;
  var data = {};
  if (link.length > 2) {
    try {
      // strip #! and parse json.
      data = JSON.parse(link.substring(2));
    } catch (e) {
      html.window.console.error("Invalid link url");
      // TODO(jacobr): redirect to default page or better yet attempt to fixup.
    }
  }
  _activeReferenceId = data['id'];
  _recomputeActiveState();
  scrollIntoView();
}

Future loadModel() {
  html.window.on.popState.add((e) {
    loadStateFromUrl();
    watchers.dispatch();
  });

  // Patch in support for [:...:]-style code to the markdown parser.
  // TODO(rnystrom): Markdown already has syntax for this. Phase this out?
  md.InlineParser.syntaxes.insertRange(0, 1,
      new md.CodeSyntax(r'\[\:((?:.|\n)*?)\:\]'));

  md.setImplicitLinkResolver(_resolveNameReference);
  var completer = new Completer();
  // TODO(jacobr): shouldn't have to get this from the parent directory.
  new html.HttpRequest.get('../static/apidoc.json', onSuccess(html.HttpRequest req) {
    for (var libraryJson in JSON.parse(req.responseText)) {
      var library = new LibraryElement(libraryJson, null);
      libraries[library.id] = library;
    }
    onDataModelChanged();
    completer.complete(true);
  });
  return completer.future;
}

/** XXX NOT USED TODO(jacobr) remove.
class DocComment {
  final String text;

  /**
   * Non-null if the comment is inherited from another declaration.
   */
  final inheritedFrom; // InterfaceMirror?

  DocComment(this.text, [this.inheritedFrom = null]) {
    assert(text != null && !text.trim().isEmpty);
  }

  SafeHtml get html => new SafeHtml.unsafe(md.markdownToHtml(text));

  String toString() => text;
}

*/

/**
 * This will be called whenever a doc comment hits a `[name]` in square
 * brackets. It will try to figure out what the name refers to and link or
 * style it appropriately.
 */
md.Node _resolveNameReference(String name) {
  // TODO(jacobr): this isn't right yet and we have made this code quite ugly
  // by using the verbose universal permalink member even though library is
  // always currentLibrary.
  makeLink(String href) {
    return new md.Element.text('a', name)
      ..attributes['href'] = href
      ..attributes['class'] = 'crossref';
  }

  // See if it's a parameter of the current method.
  if (currentMember != null && currentMember.kind == 'method') {
    var parameters = currentMember.children;
    for (final parameter in parameters) {
      if (parameter.name == name) {
        final element = new md.Element.text('span', name);
        element.attributes['class'] = 'param';
        return element;
      }
    }
  }

  // See if it's another member of the current type.
  // TODO(jacobr): fixme. this is wrong... members are by id now not simple string name...
  if (currentType != null) {
    final foundMember = currentType.members[name];
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
      var foundMember = foundType.members[match[2]];
      if (foundMember == null) return null;
      return makeLink(permalink(foundMember));
    })();
    if (foreignMemberLink != null) return foreignMemberLink;

    var foundType = currentLibrary.classes[name];
    if (foundType != null) {
      return makeLink(permalink(foundType));
    }

    // See if it's a top-level member in the current library.
    var foundMember = currentLibrary.members[name];
    if (foundMember != null) {
      return makeLink(permalink(foundMember));
    }
  }

  // TODO(jacobr): Should also consider:
  // * Names imported by libraries this library imports. Don't think we even
  //   store this in the AST.
  // * Type parameters of the enclosing type.

  return new md.Element.text('code', name);
}
