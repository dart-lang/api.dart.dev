// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * AST describing all information about Dart libraries required to render
 * Dart documentation.
 */
library ast;

import 'dart:json' as json;
import 'package:web_ui/safe_html.dart';
import 'package:markdown/markdown.dart' as md;
import 'library_loader.dart' as library_loader;
import 'model.dart' as apidoc_model;

final MAX_REFERENCES_TO_TRACK = 100;
/**
 * Top level data model for the app.
 * Mapping from String ids to [LibraryElement] objects describing all currently
 * loaded libraries. All code must be written to work properly if more libraries
 * are loaded incrementally.
 */
final libraries = <String, LibraryElement>{};

/**
 * Package being actively viewed.
 */
PackageManifest package;

/**
 * Children of a library are shown in the UI grouped by type sorted in the order
 * specified by this list.
 */
final LIBRARY_ITEMS =
    <String>['property', 'method', 'class', 'exception', 'typedef'];
/**
 * Children of a class are shown in the UI grouped by type sorted in the order
 * specified by this list.
 */
final CLASS_ITEMS =
    <String>['constructor', 'property', 'method', 'operator'];
// TODO(jacobr): add package kinds?

// TODO(jacobr): i18n
/**
 * Pretty names for the various kinds displayed.
 */
final UI_KIND_TITLES = <String, String>{
    'property': 'Variables and Properties',
    'method': 'Functions',
    'constructor': 'Constructors',
    'class': 'Classes',
    'operator': 'Operators',
    'typedef': 'Typedefs',
    'exception': 'Exceptions'
};

/**
 * Description of a package and all packages it references.
 */
class PackageManifest {

  /** Package name. */

  final name;

  /** Package description */
  final description;

  /** Libraries contained in this package. */
  final List<Reference> libraries;

  /** Descriptive string describing the version# of the package. */
  final String fullVersion;

  /** Source control revision # of the package. */
  final String revision;

  /** Path to the directory containing data files for each library. */
  final String location;

  /**
   * Packages depended on by this package.
   * We currently store the entire manifest for the depency here as it is
   * sufficiently small.  We may want to change this to a reference in the
   * future.
   */
  final List<PackageManifest> dependencies;

  PackageManifest(Map json)
      : name = json['name'],
        description = json['description'],
        libraries = json['libraries'].map(
            (json) => new Reference(json)).toList(),
        fullVersion = json['fullVersion'],
        revision = json['revision'],
        location = json['location'],
        dependencies = json['dependencies'].map(
            (json) => new PackageManifest(json)).toList();
}

/**
 * Reference to an [Element].
 */
class Reference {
  final String refId;
  final String name;
  final List<Reference> arguments;

  Reference(Map json)
      : name = json['name'],
        refId = json['refId'],
        arguments = _jsonDeserializeReferenceArray(json['arguments']);

  Reference.fromId(this.refId)
      : name = null,
        arguments = <Reference>[];

  bool operator ==(var other) {
    return other is Reference ? refId == other.refId : false;
  }

  int get hashCode => refId.hashCode;

  Element toElement() => lookupReferenceId(refId);

  String get id => refId.split('/').last;

  String get libraryId => refId.split('/').first;
  /**
   * Short description appropriate for displaying in a tree control or other
   * situtation where a short description is required.
   */
  String get shortDescription {
    if (arguments.isEmpty) {
      return shortName;
    } else {
      var params =
          arguments.map((param) => param.shortDescription).join(', ');
      return '$name<$params>';
    }
  }

  // TODO(jacobr): should this be different from name?
  /** Short version of the element's name. */
  String get shortName => name;
}

void loadLibraryJson(String data) {
  // Invalidate all caches associated with existing libraries as the world
  // of loaded libraries has changed.
  for (var library in libraries.values) {
    library.invalidate();
  }
  var libraryJson = json.parse(data);
  var libraryId = libraryJson['id'];
  if (libraryId == null) return;

  var dependenciesJson = libraryJson['dependencies'];
  if (dependenciesJson != null) {
    for (Map libraryJson in dependenciesJson) {
      var library = libraries.putIfAbsent(libraryJson['id'],
          () => new LibraryElement(libraryJson, null)..loading = true);
      // Only inject the json when the library is still loading as there is no
      // need to inject the json if the library is already complete.
      if (library.loading) {
        library._injectJson(libraryJson);
      }
    }
  }

  var library = libraries[libraryId];
  if (library != null) {
    library._injectJson(libraryJson);
    library.loading = false;
  } else {
    library = new LibraryElement(libraryJson, null);
    libraries[libraryId] = library;
  }
}

void loadPackageJson(String data) {
  if (!data.isEmpty) {
    package = new PackageManifest(json.parse(data));
    // Start loading all of the JSON associated with the package in the
    // background.
    for (var library in package.libraries) {
      library_loader.queue(library);
      libraries[library.refId] = new LibraryElement.stub(library);
    }
  }
}

/**
 * Lookup a library based on the [libraryId].
 */
LibraryElement lookupLibrary(String libraryId) {
  return libraries[libraryId];
}

/**
 * Resolve the [Element] matching the [referenceId].
 *
 * If [nearestMatch] is true and the Element cannot be found, the closest
 * known ancestor of the desired Element is returned instead.
 */
Element lookupReferenceId(String referenceId, [bool nearestMatch = false]) {
  var parts = referenceId.split(new RegExp('/'));
  var libraryId = parts.first;
  Element current = lookupLibrary(libraryId);
  if (current == null || current.loading == true) {
    library_loader.load(new Reference.fromId(libraryId));
  }
  for (var i = 1; i < parts.length && current != null; i++) {
    var id = parts[i];
    var next = null;
    for (var child in current.children) {
      if (child.id == id) {
        next = child;
        break;
      }
    }
    if (next == null) {
      return nearestMatch ? current : null;
    }
    current = next;
  }
  return current;
}

/**
 * Invoke [callback] on every [Element] in the ast.
 */
_traverseWorld(bool callback(Element)) {
  for (var library in libraries.values) {
    library.traverse(callback);
  }
}

// TODO(jacobr): remove this method when templates handle [SafeHTML] containing
// multiple top level nodes correct.
SafeHtml _markdownToSafeHtml(String text) {
  // We currently have to insert an extra span for now because of
  // https://github.com/dart-lang/web-ui/issues/212
  return new SafeHtml.unsafe(text != null && !text.isEmpty ?
      '<span>'
      '${md.markdownToHtml(text, linkResolver: apidoc_model.linkResolver)}'
      '</span>' : '<span><span>');
}

// TODO(jacobr): remove this method when templates handle [SafeHTML] containing
// multiple top level nodes correct.
SafeHtml _markdownToSafeHtmlSnippet(String text) {
  // We currently have to insert an extra span for now because of
  // https://github.com/dart-lang/web-ui/issues/212
  // TODO(efortuna?): Add an HtmlSnippet method to the package:markdown library,
  // and call it here instead of just markdownToHtml. The snippet option only
  // generates 1 paragraph of text for the code comment for a method.
  return new SafeHtml.unsafe(text != null && !text.isEmpty ?
      '<span>'
      '${md.markdownToHtml(text, linkResolver: apidoc_model.linkResolver)}'
      '</span>' : '<span><span>');
}

/**
 * Base class for all elements in the AST.
 */
class Element implements Comparable, Reference {
  final Element parent;

  /**
   * Parent of the element in the context it was originally defined.
   *
   * For example, the [toString] method from [Object] will have [Object] as its
   * original parent when it is included as a child of subclasses of [Object]
   * that do not override [toString].
   */
  final Element originalParent;

  /** Human readable type name for the node. */
  final String rawKind;

  /** Human readable name for the element. */
  final String name;

  /** Id for the node that is unique within its parent's children. */
  final String id;

  /** Raw text of the comment associated with the Element if any. */
  String comment;

  /** Whether the node is private. */
  bool isPrivate;

  /** Raw html comment for the Element from MDN. */
  String mdnCommentHtml;

  /**
   * The URL to the page on MDN that content was pulled from for the current
   * type being documented. Will be `null` if the type doesn't use any MDN
   * content.
   */
  String mdnUrl;

  /** Children of the element. */
  List<Element> _children;

  /** Whether the [Element] is currently being loaded. */
  bool loading;

  String _uri;
  String _line;
  String _refId;
  SafeHtml _commentHtml;
  SafeHtml _commentHtmlSnippet;
  List<Element> _references;
  List<Element> _typeParameters;

  Element(Map json, Element parent)
      : parent = parent,
        originalParent = parent,
        name = json['name'],
        rawKind = json['kind'],
        id = json['id'],
        loading = false {
    _loadFromJson(json);
  }

  Element._clone(Element e, Element newParent)
      : parent = newParent,
        originalParent = e.originalParent,
        name = e.name,
        rawKind = e.rawKind,
        id = e.id,
        comment = e.comment,
        isPrivate = e.isPrivate,
        mdnCommentHtml = e.mdnCommentHtml,
        mdnUrl = e.mdnUrl,
        // We intentionally copy from the computed version as otherwise the
        // inferred location could be wrong.
        _uri = e.uri,
        _line = e.line,
        loading = false,
        _children = e._children;

  Element.stub(this.rawKind, Reference ref)
      : this.name = ref.name,
        this.id = ref.id,
        loading = true,
        comment = null,
        isPrivate = false,
        _uri = null,
        _line = null,
        parent = null,
        originalParent = null,
        mdnCommentHtml = null,
        mdnUrl = null,
        _children = <Element>[];

  void _loadFromJson(Map json) {
    comment = json['comment'];
    isPrivate = json['isPrivate'] == true;
    mdnCommentHtml = json['mdnCommentHtml'];
    mdnUrl = json['mdnUrl'];
    _uri = json['uri'];
    _line = json['line'];
    _addChildren(json['children']);
  }

  void _addChildren(List children) {
    if (_children == null) {
      _children = _jsonDeserializeArray(children, this);
    } else {
      // TODO(jacobr): evaluate keeping around the list of existing children.
      var existingChildren = new Set<String>.from(
          _children.map((e) => e.id));

      for (var child in children) {
        if (!existingChildren.contains(child['id'])) {
          _children.add(jsonDeserialize(child, this));
        }
      }
    }
  }

  /**
   * Create a clone of the element with a different parent.
   */
  Element clone(Element newParent) => new Element._clone(this, newParent);

  bool operator ==(other) {
    return other is Reference ? refId == other.refId : false;
  }

  int get hashCode => refId.hashCode;

  /** Children of the element. */
  List<Element> get children => _children;

  Element toElement() => this;

  /**
   * Concrete elements do not take arguments.
   */
  List<Reference> get arguments => <Reference>[];

  /**
   * Subclasses must remove all cached data that could be stale due to loading
   * additional libraries.
   */
  void invalidate() {
    _references = null;
    for (var child in children) {
      child.invalidate();
    }
  }

  /**
   * Returns a kind name that make sense for the UI rather than the AST
   * kinds.  For example, setters are considered properties instead of
   * methods in the UI but not the AST.
   */
  String get uiKind => kind;

  /**
   * Returns a kind name that make sense for grouping like elements in the UI
   * rather than the AST kinds.  For example, setters are considered properties
   * instead of methods in the UI but not the AST.
   */
  String get uiKindGroup => kind;

  /**
   * Longer possibly multiple word description of the [kind].
   */
  String get kindDescription => uiKind;

  /** Invoke [callback] on this [Element] and all descendants. */
  void traverse(bool callback(Element)) {
    if (!callback(this)) return;
    for (var child in children) {
      child.traverse(callback);
    }
  }

  /**
   * Uri containing the source code for the definition of the element.
   */
  String get uri => _uri != null ? _uri : (parent != null ? parent.uri : null);

  /*** Possibly shortened human readable name for an element. */
  String get shortName => name;

  /**
   * Line in the original source file that begins the definition of the element.
   */
  String get line => _line != null ?
      _line : (parent != null ? parent.line : null);

  /**
   *  Globally unique identifier for this element.
   */
  String get refId {
    if (_refId == null) {
      _refId = (parent == null) ? id : '${parent.refId}/$id';
    }
    return _refId;
  }

  /**
   * Whether this [Element] references the specified [referenceId].
   */
  bool hasReference(String referenceId) =>
    children.any((child) => child.hasReference(referenceId));

  /** Returns all [Element]s that reference this [Element]. */
  List<Element> get references {
    if (_references == null) {
      _references = <Element>[];
      _traverseWorld((element) {
        if (_references.length >= MAX_REFERENCES_TO_TRACK) {
          // We have already found enough references.
          return false;
        }

        if (element == this) {
          // We aren't interested in self references.
          return false;
        }

        if (element.hasReference(refId)) {
          _references.add(element);
        }
        return true;
      });
    }
    return _references;
  }

  /** Path from the root of the tree to this [Element]. */
  List<Element> get path {
    if (parent == null) {
      return <Element>[this];
    } else {
      return parent.path..add(this);
    }
    // TODO(jacobr): replace this code with:
    // return (parent == null) ? <Element>[this] : (parent.path..add(this));
    // once http://code.google.com/p/dart/issues/detail?id=7665 is fixed.
  }

  LibraryElement get library => path.first;

  List<Element> get typeParameters {
    if (_typeParameters == null) {
      _typeParameters = _filterByKind('typeparam');
    }
    return _typeParameters;
  }

  /**
   * [SafeHtml] for the comment associated with this [Element] generated from
   * the markdown comment associated with the element.
   */
  SafeHtml get commentHtml {
    if (_commentHtml == null) {
      if (comment == null && mdnCommentHtml != null) {
        _commentHtml = new SafeHtml.unsafe("""
            <div class="mdn">
              $mdnCommentHtml
              <div class="mdn-note"><a href="$mdnUrl">from MDN</a></div>
            </div>""");
      } else {
        _commentHtml = _markdownToSafeHtml(comment);
      }
    }
    return _commentHtml;
  }

  /**
   * [SafeHtml] for the first line or so of comment associated with this
   * [Element] generated from the first block of content in the markdown
   * associated with the element.
   */
  SafeHtml get commentHtmlSnippet {
    if (_commentHtmlSnippet == null) {
      if (comment == null && mdnCommentHtml != null) {
        // TODO(jacobr): extract the first paragraph from the MDN comment
        // to reduce the size of the DOM.
        _commentHtmlSnippet = new SafeHtml.unsafe("""
            <span class="mdn">
              $mdnCommentHtml
              <span class="mdn-note"><a href="$mdnUrl">from MDN</a></span>
            </span>""");
      } else {
        _commentHtmlSnippet = _markdownToSafeHtmlSnippet(comment);
      }
    }
    return _commentHtmlSnippet;
  }

  /**
   * Short description appropriate for display in a tree control or other
   * situtation where a short description is required.
   */
  String get shortDescription {
    if (typeParameters.isEmpty) {
      return name;
    } else {
      var params =
          typeParameters.map((param) => param.shortDescription).join(', ');
      return '$name<$params>';
    }
  }

  /**
   * Long description appropriate for display in a tooltip or other situation
   * where a long description is expected.
   */
  String get longDescription => shortDescription;

  /**
   * Ui specific representation of the node kind.
   * For example, currently operators are considered their own kind even though
   * they aren't their own kind in the AST.
   */
  String get kind => rawKind;

  /**
   * Generate blocks of Elements for each kind in the list of [desiredKinds].
   *
   * This is helpful when rendering UI that segments members into blocks.
   * Uses the kind types that make sense for the UI rather than the AST
   * kinds.  For example, setters are considered properties instead of methods.
   */
  List<ElementBlock> _createElementBlocks(List<String> desiredKinds,
      bool showPrivate, showInherited) {
    var blockMap = new Map<String, List<Element>>();

    for (var child in children) {
      // TODO(jacobr): don't hard code $dom_
      if (showPrivate == false &&
          (child.isPrivate || child.name.startsWith("\$dom_"))) {
        continue;
      }

      if (showInherited == false && child.originalParent != child.parent) {
        continue;
      }

      if (!desiredKinds.contains(child.uiKind)) {
        continue;
      }
      blockMap.putIfAbsent(child.uiKind, () => <Element>[]).add(child);
    }

    var blocks = <ElementBlock>[];
    for (var kind in desiredKinds) {
      var elements = blockMap[kind];
      if (elements != null) {
        blocks.add(new ElementBlock(kind, elements..sort()));
      }
    }
    return blocks;
  }

  List<Element> _filterByKind(String kind) =>
      children.where((child) => child.kind == kind).toList();

  Map<String, Element> _mapForKind(String kind) {
    Map ret = {};
    if (children == null) return ret;

    for (var child in children) {
      if (child.kind == kind) {
        ret[child.id] = child;
      }
    }
    return ret;
  }

  /**
   * Specifies the order elements should appear in the UI.
   */
  int compareTo(Element other) {
    if (isPrivate != other.isPrivate) {
      return other.isPrivate ? 1 : -1;
    }
    // TODO(jacobr): is there a compareNoCase member we can use that I am just
    // missing?
    return name.toLowerCase().compareTo(other.name.toLowerCase());
  }
}

/**
 * [Element] describing a Dart library.
 *
 * Adds convenience helpers for quickly accessing data about libraries.
 */
class LibraryElement extends Element {
  Map<String, ClassElement> _classes;

  LibraryElement(json, Element parent)
      : super(json, parent);
  LibraryElement.stub(Reference ref)
      : super.stub('library', ref);

  LibraryElement._clone(LibraryElement e, Element newParent)
      : super._clone(e, newParent);

  LibraryElement clone(Element newParent) =>
      new LibraryElement._clone(this, newParent);

  /** Returns all classes defined by the library. */
  Map<String, ClassElement> get classes {
    if (_classes == null) {
      _classes = _mapForKind('class');
    }
    return _classes;
  }

  void _injectJson(Map json) {
    _loadFromJson(json);
    _classes = null; // clear _classes cache.
  }

  String get libraryId => id;

  /**
   * Returns all blocks of elements that should be rendered by UI summarizing
   * the Library.
   */
  List<ElementBlock> childBlocks(bool showPrivate) =>
      _createElementBlocks(LIBRARY_ITEMS, showPrivate, false);

  List<Element> sortedChildren(bool showPrivate) {
    var ret = <Element>[];
    for (var block in childBlocks(showPrivate)) {
      ret.addAll(block.elements);
    }
    return ret;
  }
}

/**
 * [Element] describing a Dart class.
 */
class ClassElement extends Element {
  /** Interfaces the class directly implements. */
  final List<Reference> _directInterfaces;
  List<Reference> _interfaces;

  /** Superclass of this class. */
  final Reference superclass;

  /** Whether the class is abstract. */
  final bool isAbstract;

  /** Whether the class implements or extends [Error] or [Exception]. */
  bool isThrowable;

  List<ClassElement> _superclasses;
  List<ClassElement> _subclasses;

  /**
   * Whether we have grabbed all children from the parent classes and added
   * them as children of this class.
   */
  bool _childrenBreaded;

  ClassElement(Map json, Element parent)
    : super(json, parent),
      _directInterfaces = _jsonDeserializeReferenceArray(json['interfaces']),
      superclass = jsonDeserializeReference(json['superclass']),
      isAbstract = json['isAbstract'] == true,
      isThrowable = json['isThrowable'] == true;

  ClassElement._clone(ClassElement e, Element newParent)
      : super._clone(e, newParent),
        _directInterfaces = e._directInterfaces,
        superclass = e.superclass,
        isAbstract = e.isAbstract,
        isThrowable = e.isThrowable;

  ClassElement clone(Element newParent) =>
      new ClassElement._clone(this, newParent);

  String get uiKind => isThrowable ? 'exception' : kind;

  void invalidate() {
    _subclasses = null;
    super.invalidate();
  }

  List<Element> get children {
    if (_childrenBreaded != true) {
      _breadChildren();
      _childrenBreaded = true;
    }
    return _children;
  }

  /**
   * Inject children from superclasses, copying their comments for cases where
   * the child class had no comments.
   */
  void _breadChildren() {
    // Map from id prefixes to cannonical versions.
    var existingMap = new Map<String, Element>();

    _breadHelper(e) {
      for (var child in e._children) {
        // Showing constructors from superclasses doesn't make sense.
        if (e != this && child is ConstructorElement) {
          continue;
        }
        var existing = existingMap[child.id];
        // Use comment from superclass if available.
        // TODO(jacobr): this is a bit ugly... we are mutating the
        // comments. The trouble is we can't safely bread at load time due
        // to cross package dependencies and the fact that we need to lazy
        // load packages.
        if (existing != null) {
          if (existing.comment == null) {
            existing.comment = child.comment;
          }
          if (existing.mdnCommentHtml == null) {
            existing.mdnCommentHtml = child.mdnCommentHtml;
            existing.mdnUrl = child.mdnUrl;
          }
          continue;
        }
        if (e != this) {
          child = child.clone(this);
          this._children.add(child);
        }
        existingMap[child.id] = child;
      }
    }
    _breadHelper(this);
    for (var superclass in superclasses.reversed) {
      _breadHelper(superclass);
    }
    for (var interface in interfaces) {
      _breadHelper(interface);
    }
  }

  /** Returns all superclasses of this class. */
  List<ClassElement> get superclasses {
    if (_superclasses == null) {
      _superclasses = <ClassElement>[];
      addSuperclasses(clazz) {
        if (clazz.superclass != null) {
          var superclassElement = clazz.superclass.toElement();
          if (superclassElement != null) {
            addSuperclasses(superclassElement);
            _superclasses.add(superclassElement);
          }
        }
      }
      addSuperclasses(this);
    }
    return _superclasses;
  }

  /** Returns all interfaces implemented by this class. */
  List<ClassElement> get interfaces {
    if (_interfaces == null) {
      final allInterfaces = new Set<ClassElement>();
      final superclassSet = superclasses.toSet();

      addInterface(ClassElement ref) {
        if (!superclassSet.contains(ref)) {
          allInterfaces.add(ref);
        }
      }
      addInterfaces(Iterable<ClassElement> refs) {
        for(var ref in refs) {
          addInterface(ref);
        }
      }

      for (var ref in _directInterfaces) {
        var interface = ref.toElement();
        addInterfaces(interface.interfaces);
        addInterfaces(interface.superclasses);
        addInterface(interface);
      }
      for (var superClass in superclasses) {
        addInterfaces(superClass.interfaces);
      }
      _interfaces = allInterfaces.toList();
    }
    return _interfaces;
  }

  String get kindDescription =>
      isAbstract ? 'abstract $uiKind' : uiKind;

  /**
   * Returns classes that directly extend or implement this class.
   */
  List<ClassElement> get subclasses {
    if (_subclasses == null) {
      _subclasses = <ClassElement>[];
      for (var library in libraries.values) {
        for (ClassElement candidateClass in library.classes.values) {
          if (candidateClass.implementsOrExtends(refId)) {
            _subclasses.add(candidateClass);
          }
        }
      }
    }
    return _subclasses;
  }

  /**
   * Returns whether this class directly extends or implements the specified
   * class.
   */
  bool implementsOrExtends(String referenceId) {
    for (Reference interface in interfaces) {
      if (interface.refId == referenceId) return true;
    }
    return superclass != null && superclass.refId == referenceId;
  }

  /**
   * Returns blocks of elements clustered by kind ordered in the desired
   * order for describing a class definition.
   */
  List<ElementBlock> childBlocks(bool showPrivate, bool showInherited) =>
      _createElementBlocks(CLASS_ITEMS, showPrivate, showInherited);

  List<Element> sortedChildren(bool showPrivate, bool showInherited) {
    var ret = <Element>[];
    for (var block in childBlocks(showPrivate, showInherited)) {
      ret.addAll(block.elements);
    }
    return ret;
  }
}

// TODO(jacobr): make this a mixin when possible.
/**
 * Element with a return type and parameters
 */
class FunctionLikeElement extends Element {
  final Reference returnType;
  List<Element> _parameters;

  FunctionLikeElement(Map json, Element parent)
      : super(json, parent),
        returnType = jsonDeserializeReference(json['returnType']);

  FunctionLikeElement._clone(FunctionLikeElement e, Element newParent)
      : super._clone(e, newParent),
        returnType = e.returnType;

  /**
   * Returns a list of the parameters of the typedef.
   */
  List<Element> get parameters {
    if (_parameters == null) {
      _parameters = _filterByKind('param');
    }
    return _parameters;
  }

  List<Element> get requiredParameters => parameters;

  List<Element> get optionalParameters => <Element>[];
}

/**
 * Element describing a typedef.
 */
class TypedefElement extends FunctionLikeElement {
  TypedefElement(Map json, Element parent)
      : super(json, parent);

  TypedefElement._clone(TypedefElement e, Element newParent)
      : super._clone(e, newParent);

  TypedefElement clone(Element newParent) =>
      new TypedefElement._clone(this, newParent);
}

/**
 * [Element] describing a method which may be a regular method, a setter, or an
 * operator.
 */
abstract class MethodLikeElement extends Element {

  final bool isOperator;
  final bool isStatic;
  final bool isSetter;

  Reference get returnType;
  List<ParameterElement> _parameters;
  List<ParameterElement> _optionalParameters;
  List<ParameterElement> _requiredParameters;

  MethodLikeElement(Map json, Element parent)
    : super(json, parent),
      isOperator = json['isOperator'] == true,
      isStatic = json['isStatic'] == true,
      isSetter = json['isSetter'] == true;

  MethodLikeElement._clone(MethodLikeElement e, Element newParent)
      : super._clone(e, newParent),
        isOperator = e.isOperator,
        isStatic = e.isStatic,
        isSetter = e.isSetter;

  void traverse(void callback(Element)) {
    callback(this);
  }

  bool hasReference(String referenceId) {
    if (super.hasReference(referenceId)) return true;
    return returnType != null && returnType.refId == referenceId;
  }

  String get uiKind => isSetter ? 'property' : kind;

  String get shortName {
    if (isSetter) {
      return name.substring(0, name.length - 1);
    } else {
      return name;
    }
  }

  /**
   * Returns a plain text short description of the method suitable for rendering
   * in a tree control or other case where a short method description is
   * required.
   */
  String get shortDescription {
    return '$shortName(${
        parameters.map((arg) => arg.shortDescription).join(', ')})';
  }

  String get longDescription {
    var sb = new StringBuffer();
    if (isStatic) {
      sb.write("static ");
    }
    if (isSetter) {
      sb.write("set $shortName(");
      if (!parameters.isEmpty && parameters.first != null) {
        if (parameters.first.type != null) {
          sb..write(parameters.first.longDescription)..write(' ');
        }
        sb.write(parameters.first.name);
      }
      sb.write(")");
    } else {
      if (returnType != null) {
        sb..write(returnType.shortDescription)..write(" ");
      }
      if (isOperator) {
        sb.write("operator ");
      }
      sb.write('$name(${parameters.map(
          (arg) => arg.longDescription).toList().join(', ')})');
    }
    return sb.toString();
  }

  /**
   * Returns a list of the parameters of the Method.
   */
  List<ParameterElement> get parameters {
    if (_parameters == null) {
      _parameters = _filterByKind('param');
    }
    return _parameters;
  }

  /**
   * Returns a list of optional parameters of the Method.
   */
  List<ParameterElement> get optionalParameters {
    if (_optionalParameters == null) {
      _computeOptionalAndRequiredParameters();
    }
    return _optionalParameters;
  }

  String get optionalParametersStartSymbol =>
      optionalParameters.first.isNamed ? '{' : '[';

  String get optionalParametersEndSymbol =>
      optionalParameters.first.isNamed ? '}' : ']';

  /**
   * Returns a list of optional parameters of the Method.
   */
  List<ParameterElement> get requiredParameters {
    if (_requiredParameters == null) {
      _computeOptionalAndRequiredParameters();
    }
    return _requiredParameters;
  }

  void _computeOptionalAndRequiredParameters() {
    _requiredParameters = <ParameterElement>[];
    _optionalParameters = <ParameterElement>[];
    for (var parameter in parameters) {
      if (parameter.isOptional) {
        _optionalParameters.add(parameter);
      } else {
        _requiredParameters.add(parameter);
      }
    }
  }

  /// For UI purposes we want to treat operators as their own kind.
  String get kind => isOperator ? 'operator' : rawKind;
}

/**
 * Element describing a parameter.
 */
class ParameterElement extends Element {
  /** Type of the parameter. */
  final Reference _type;

  /**
   * Returns the default value for this parameter.
   */
  final String defaultValue;

  /**
   * Is this parameter optional?
   */
  final bool isOptional;

  /**
   * Is this parameter named?
   */
  final bool isNamed;

  /**
   * Returns the initialized field, if this parameter is an initializing formal.
   */
  final Reference initializedField;

  ParameterElement(Map json, Element parent)
      : super(json, parent),
        _type = jsonDeserializeReference(json['ref']),
        defaultValue = json['defaultValue'],
        isOptional = json['isOptional'] == true,
        isNamed = json['isNamed'] == true,
        initializedField = jsonDeserializeReference(json['initializedField']);

  ParameterElement._clone(ParameterElement e, Element newParent)
      : super._clone(e, newParent),
        _type = e.type,
        defaultValue = e.defaultValue,
        isOptional = e.isOptional,
        isNamed = e.isNamed,
        initializedField = e.initializedField;

  ParameterElement clone(Element newParent) =>
      new ParameterElement._clone(this, newParent);

  Reference get type {
    if (children.length > 0) {
      assert(children.length == 1 && children.first is FunctionTypeElement);
      return children.first;
    } else {
      return _type;
    }
  }
  bool hasReference(String referenceId) {
    if (super.hasReference(referenceId)) return true;
    return type != null && type.refId == referenceId;
  }

  String get shortDescription {
    return type == null ? 'var' : type.shortDescription;
  }

  String get longDescription {
    var sb = new StringBuffer();
    if (initializedField != null) {
      sb.write("this.");
    } else if (type != null) {
      sb..write(type.shortDescription)..write(' ');
    }
    sb.write(name);
    if (defaultValue != null) {
      sb.write(' = $defaultValue');
    }
    return sb.toString();
  }
}

/**
 * Element describing a function type.
 */
class FunctionTypeElement extends FunctionLikeElement {
  FunctionTypeElement(Map json, Element parent)
      : super(json, parent);

  FunctionTypeElement._clone(FunctionTypeElement e, Element newParent)
      : super._clone(e, newParent);

  FunctionTypeElement clone(Element newParent) =>
      new FunctionTypeElement._clone(this, newParent);
}

/**
 * Element describing a generic type parameter.
 */
class TypeParameterElement extends Element {
  /** Upper bound for the parameter. */
  Reference upperBound;

  TypeParameterElement(Map json, Element parent)
      : super(json, parent),
        upperBound = jsonDeserializeReference(json['upperBound']);

  String get shortDescription {
    if (upperBound == null) {
      return name;
    } else {
      return '$name extends ${upperBound.shortDescription}';
    }
  }

  bool hasReference(String referenceId) {
    if (super.hasReference(referenceId)) return true;
    return upperBound != null && upperBound.refId == referenceId;
  }
}

/**
 * Element describing a method.
 */
class MethodElement extends MethodLikeElement {

  final Reference returnType;

  MethodElement(Map json, Element parent)
      : super(json, parent),
        // TODO(jacobr): remove the returnType check once the json output is
        // updated.
        returnType =  json['isSetter'] != true ?
            jsonDeserializeReference(json['returnType']) : null;

  MethodElement._clone(MethodElement e, Element newParent)
      : super._clone(e, newParent),
        returnType = e.returnType;

  MethodElement clone(Element newParent) =>
      new MethodElement._clone(this, newParent);
}

/**
 * Element describing a property getter.
 */
class PropertyElement extends MethodLikeElement {
  final Reference returnType;

  String get shortDescription => name;

  PropertyElement(Map json, Element parent)
      : super(json, parent),
        returnType = jsonDeserializeReference(json['ref']);

  PropertyElement._clone(PropertyElement e, Element newParent)
      : super._clone(e, newParent),
        returnType = e.returnType;

  PropertyElement clone(Element newParent) =>
      new PropertyElement._clone(this, newParent);

  String get longDescription {
    var sb = new StringBuffer();
    if (returnType != null) {
      sb..write(returnType.shortDescription)..write(" ");
    }
    sb.write("get $name");
    return sb.toString();
  }

  void traverse(void callback(Element)) {
    callback(this);
  }
}

/**
 * Element describing a variable.
 */
class VariableElement extends MethodLikeElement {
  final Reference returnType;
  /** Whether this variable is final. */
  final bool isFinal;

  String get shortDescription => name;

  String get longDescription {
    var sb = new StringBuffer();
    if (returnType != null) {
      sb..write(returnType.shortDescription)..write(" ");
    }
    sb.write(name);
    return sb.toString();
  }

  /**
   * Group variables and properties together in the UI as they are
   * interchangeable as far as users are concerned.
   */
  String get uiKind => 'property';

  VariableElement(Map json, Element parent)
      : super(json, parent),
        returnType = jsonDeserializeReference(json['ref']),
        isFinal = json['isFinal'];

  VariableElement._clone(VariableElement e, Element newParent)
      : super._clone(e, newParent),
        returnType = e.returnType,
        isFinal = e.isFinal;

  VariableElement clone(Element newParent) =>
      new VariableElement._clone(this, newParent);

  void traverse(void callback(Element)) {
    callback(this);
  }
}

/**
 * Element describing a constructor.
 */
class ConstructorElement extends MethodLikeElement {
  ConstructorElement(json, Element parent)
      : super(json, parent);

  ConstructorElement._clone(ConstructorElement e, Element newParent)
      : super._clone(e, newParent);

  ConstructorElement clone(Element newParent) =>
      new ConstructorElement._clone(this, newParent);

  Reference get returnType => null;

  void traverse(void callback(Element)) {
    callback(this);
  }
}

/**
 * Block of elements to render summary documentation for all elements that share
 * the same kind.
 *
 * For example, all properties, all functions, or all constructors.
 */
class ElementBlock {
  final String kind;
  final List<Element> elements;

  ElementBlock(this.kind, this.elements);

  String get kindCssClass => "kind-$kind";
  String get kindTitle => UI_KIND_TITLES[kind];

  bool operator ==(ElementBlock other) {
    if (kind != other.kind) return false;
    if (elements.length != other.elements.length) return false;
    for (int i = 0; i < elements.length; i++) {
      if (elements[i] != other.elements[i]) return false;
    }
    return true;
  }
}

Reference jsonDeserializeReference(Map json) {
  return json != null ? new Reference(json) : null;
}

/**
 * Deserializes JSON into an [Element] object.
 */
Element jsonDeserialize(Map json, Element parent) {
  if (json == null) return null;

  var kind = json['kind'];
  if (kind == null) {
    throw "Unable to deserialize $json";
  }

  switch (kind) {
    case 'class':
      return new ClassElement(json, parent);
    case 'typedef':
      return new TypedefElement(json, parent);
    case 'typeparam':
      return new TypeParameterElement(json, parent);
    case 'library':
      return new LibraryElement(json, parent);
    case 'method':
      return new MethodElement(json, parent);
    case 'property':
      return new PropertyElement(json, parent);
    case 'constructor':
      return new ConstructorElement(json, parent);
    case 'variable':
      return new VariableElement(json, parent);
    case 'param':
      return new ParameterElement(json, parent);
    case 'functiontype':
      return new FunctionTypeElement(json, parent);
    default:
      return new Element(json, parent);
  }
}

List<Element> _jsonDeserializeArray(List json, Element parent) {
  var ret = <Element>[];
  if (json == null) return ret;

  for (Map elementJson in json) {
    ret.add(jsonDeserialize(elementJson, parent));
  }
  return ret;
}

List<Reference> _jsonDeserializeReferenceArray(List json) {
  var ret = <Reference>[];
  if (json == null) return ret;

  for (Map referenceJson in json) {
    ret.add(new Reference(referenceJson));
  }
  return ret;
}
