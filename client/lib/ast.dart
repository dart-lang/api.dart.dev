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
import 'markdown.dart' as md;
import 'library_loader.dart' as library_loader;

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
final LIBRARY_ITEMS = <String>['property', 'method', 'class',
                              'exception', 'typedef'];
/**
 * Children of a class are shown in the UI grouped by type sorted in the order
 * specified by this list.
 */
final CLASS_ITEMS = <String>['constructor', 'property', 'method',
                            'operator'];
// TODO(jacobr): add package kinds?

// TODO(jacobr): i18n
/**
 * Pretty names for the various kinds displayed.
 */
final KIND_TITLES = <String, String>{
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
  final List<String> libraries;
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

  PackageManifest(Map json) :
    name = json['name'],
    description = json['description'],
    libraries = json['libraries'],
    fullVersion = json['fullVersion'],
    revision = json['revision'],
    location = json['location'],
    dependencies = json['dependencies'].mappedBy(
        (json) => new PackageManifest(json)).toList();
}

/**
 * Reference to an [Element].
 */
class Reference {
  final String refId;
  final String name;
  final List<Reference> arguments;

  Reference(Map json) :
    name = json['name'],
    refId = json['refId'],
    arguments = _jsonDeserializeReferenceArray(json['arguments']);

  /**
   * Short description appropriate for displaying in a tree control or other
   * situtation where a short description is required.
   */
  String get shortDescription {
    if (arguments.isEmpty) {
      return shortName;
    } else {
      var params = Strings.join(
          arguments.mappedBy((param) => param.shortDescription), ', ');
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
  var library = new LibraryElement(json.parse(data), null);
  libraries[library.id] = library;
}

void loadPackageJson(String data) {
  if (!data.isEmpty) {
    package = new PackageManifest(json.parse(data));
    // Start loading all of the JSON associated with the package in the
    // background.
    for (var library in package.libraries) {
      library_loader.queue(library);
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
 * If the Element cannot be found, a stub dummy [Element] will be returned.
 */
Element lookupReferenceId(String referenceId) {
  var parts = referenceId.split(new RegExp('/'));
  var libraryName = parts.first;
  Element current = lookupLibrary(libraryName);
  if (current == null) {
    library_loader.load(libraryName);
    // TODO(jacobr): return a Reference instead for the case where the library
    // is not loaded yet.
    return null;
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
        '<span>${md.markdownToHtml(text)}</span>' : '<span><span>');
}

// TODO(jacobr): remove this method when templates handle [SafeHTML] containing
// multiple top level nodes correct.
SafeHtml _markdownToSafeHtmlSnippet(String text) {
  // We currently have to insert an extra span for now because of
  // https://github.com/dart-lang/web-ui/issues/212
  return new SafeHtml.unsafe(text != null && !text.isEmpty ?
        '<span>${md.markdownToHtmlSnippet(text)}</span>' : '<span><span>');
}

/**
 * Base class for all elements in the AST.
 */
class Element implements Comparable {
  final Element parent;

  /** Human readable type name for the node. */
  final String rawKind;

  /** Human readable name for the element. */
  final String name;

  /** Id for the node that is unique within its parent's children. */
  final String id;

  /** Raw text of the comment associated with the Element if any. */
  final String comment;

  /** Whether the node is private. */
  final bool isPrivate;

  /** Children of the node. */
  List<Element> children;

  /** Whether the [Element] is currently being loaded. */
  final bool loading;

  final String _uri;
  final String _line;
  String _refId;
  SafeHtml _commentHtml;
  SafeHtml _commentHtmlSnippet;
  List<Element> _references;
  List<Element> _typeParameters;

  Element(Map json, this.parent) :
    name = json['name'],
    rawKind = json['kind'],
    id = json['id'],
    comment = json['comment'],
    isPrivate = json['isPrivate'] == true,
    _uri = json['uri'],
    _line = json['line'],
    loading = false {
    children = _jsonDeserializeArray(json['children'], this);
  }

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
      _commentHtml = _markdownToSafeHtml(comment);
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
      _commentHtmlSnippet = _markdownToSafeHtmlSnippet(comment);
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
      var params = Strings.join(
          typeParameters.mappedBy((param) => param.shortDescription).toList(),
          ', ');
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
    var usedNames = new Map<String, Element>();
    _createElementBlocksHelper(e) {
      for (var child in e.children) {
        // TODO(jacobr): don't hard code $dom_
        if (showPrivate == false &&
            (child.isPrivate || child.name.startsWith("\$dom_"))) {
          continue;
        }

        // Showing constructors from superclasses doesn't make sense.
        if (e != this && child is ConstructorElement) {
          continue;
        }

        // If we are showing inherited methods, insure we do not include
        // multiple members with the same names but different types.
        // TODO(jacobr): show documentation from base class if it is available
        // while class specific definition isn't.
        if (showInherited) {
          if (usedNames.containsKey(child.name) && usedNames[child.name] != e) {
            continue;
          }
          usedNames[child.name] = e;
        }
        if (desiredKinds.contains(child.uiKind)) {
          blockMap.putIfAbsent(child.uiKind, () => <Element>[]).add(child);
        }
      }
    }
    _createElementBlocksHelper(this);
    if (showInherited && this is ClassElement) {
      for (var superclass in (this as ClassElement).superclasses.reversed) {
        _createElementBlocksHelper(superclass);
      }
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
    return name.compareTo(other.name);
  }
}

/**
 * [Element] describing a Dart library.
 *
 * Adds convenience helpers for quickly accessing data about libraries.
 */
class LibraryElement extends Element {
  Map<String, ClassElement> _classes;
  List<ClassElement> _sortedClasses;

  LibraryElement(json, Element parent) : super(json, parent);

  /** Returns all classes defined by the library. */
  Map<String, ClassElement> get classes {
    if (_classes == null) {
      _classes = _mapForKind('class');
    }
    return _classes;
  }

  /**
   * Returns all classes defined by the library sorted name and whether they
   * are private.
   */
  List<ClassElement> get sortedClasses {
    if (_sortedClasses == null) {
      _sortedClasses = []..addAll(classes.values)..sort();
    }
    return _sortedClasses;
  }

  /**
   * Returns all blocks of elements that should be rendered by UI summarizing
   * the Library.
   */
  List<ElementBlock> childBlocks(bool showPrivate, bool showInherited) =>
      _createElementBlocks(LIBRARY_ITEMS, showPrivate, showInherited);
}

/**
 * [Element] describing a Dart class.
 */
class ClassElement extends Element {

  /** Members of the class grouped into logical blocks. */
  List<ElementBlock> _childBlocks;
  /** Children sorted in the same order as [_childBlocks]. */
  List<Element> _sortedChildren;

  /** Interfaces the class implements. */
  final List<Reference> interfaces;

  /** Superclass of this class. */
  final Reference superclass;

  /** Whether the class is abstract. */
  final bool isAbstract;

  List<ClassElement> _superclasses;
  List<ClassElement> _subclasses;

  ClassElement(Map json, Element parent)
    : super(json, parent),
      interfaces = _jsonDeserializeReferenceArray(json['interfaces']),
      superclass = jsonDeserializeReference(json['superclass']),
      isAbstract = json['isAbstract'] == true;

  void invalidate() {
    _superclasses = null;
    _subclasses = null;
    super.invalidate();
  }


  /** Returns all superclasses of this class. */
  List<ClassElement> get superclasses {
    if (_superclasses == null) {
      _superclasses = <ClassElement>[];
      addSuperclasses(clazz) {
        if (clazz.superclass != null) {
          var superclassElement = lookupReferenceId(clazz.superclass.refId);
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

  String get kindDescription =>
      isAbstract ? 'abstract $uiKind' : uiKind;

  /**
   * Returns classes that directly extend or implement this class.
   */
  List<ClassElement> get subclasses {
    if (_subclasses == null) {
      _subclasses = <ClassElement>[];
      for (var library in libraries.values) {
        for (ClassElement candidateClass in library.sortedClasses) {
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

/**
 * Element describing a typedef.
 */
class TypedefElement extends Element {
  final Reference returnType;
  List<Element> _parameters;

  TypedefElement(Map json, Element parent) : super(json, parent),
      returnType = jsonDeserializeReference(json['returnType']);

  /**
   * Returns a list of the parameters of the typedef.
   */
  List<Element> get parameters {
    if (_parameters == null) {
      _parameters = _filterByKind('param');
    }
    return _parameters;
  }
}

/**
 * [Element] describing a method which may be a regular method, a setter, or an
 * operator.
 */
abstract class MethodLikeElement extends Element {

  final bool isOperator;
  final bool isStatic;
  final bool isSetter;

  MethodLikeElement(Map json, Element parent)
    : super(json, parent),
      isOperator = json['isOperator'] == true,
      isStatic = json['isStatic'] == true,
      isSetter = json['isSetter'] == true;

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
    if (isSetter) {
      var sb = new StringBuffer(shortName);
      if (!parameters.isEmpty && parameters.first != null
          && parameters.first.type != null) {
        sb..add(' ')..add(parameters.first.type.name);
      }
      return sb.toString();
    }
    return '$name(${Strings.join(parameters.mappedBy(
        (arg) => arg.shortDescription), ', ')})';
  }

  String get longDescription {
    var sb = new StringBuffer();
    if (isStatic) {
      sb.add("static ");
    }
    if (isSetter) {
      sb.add("set $shortName(");
      if (!parameters.isEmpty && parameters.first != null) {
        if (parameters.first.type != null) {
          sb..add(parameters.first.longDescription)..add(' ');
        }
        sb.add(parameters.first.name);
      }
      sb.add(")");
    } else {
      if (returnType != null) {
        sb..add(returnType.shortDescription)..add(" ");
      }
      if (isOperator) {
        sb.add("operator ");
      }
      sb.add('$name(${Strings.join(parameters.mappedBy(
          (arg) => arg.longDescription).toList(), ', ')})');
    }
    return sb.toString();
  }

  Reference get returnType;
  List<ParameterElement> _parameters;

  /**
   * Returns a list of the parameters of the Method.
   */
  List<ParameterElement> get parameters {
    if (_parameters == null) {
      _parameters = _filterByKind('param');
    }
    return _parameters;
  }

  /// For UI purposes we want to treat operators as their own kind.
  String get kind => isOperator ? 'operator' : rawKind;
}

/**
 * Element describing a parameter.
 */
class ParameterElement extends Element {
  /** Type of the parameter. */
  final Reference type;
  /** Whether the parameter is optional. */
  final bool isOptional;

  ParameterElement(Map json, Element parent) :
      super(json, parent),
      type = jsonDeserializeReference(json['ref']),
      isOptional = json['isOptional'];

  bool hasReference(String referenceId) {
    if (super.hasReference(referenceId)) return true;
    return type != null && type.refId == referenceId;
  }

  String get shortDescription {
    return type == null ? 'var' : type.shortDescription;
  }

  String get longDescription {
    return type == null ? name : '${type.shortDescription} $name';
  }
}

/**
 * Element describing a generic type parameter.
 */
class TypeParameterElement extends Element {
  /** Upper bound for the parameter. */
  Reference upperBound;

  TypeParameterElement(Map json, Element parent) :
    super(json, parent),
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

  MethodElement(Map json, Element parent) : super(json, parent),
      // TODO(jacobr): remove the returnType check once the json output is
      // updated.
      returnType =  json['isSetter'] != true ?
          jsonDeserializeReference(json['returnType']) : null;
}

/**
 * Element describing a property getter.
 */
class PropertyElement extends MethodLikeElement {
  final Reference returnType;

  String get shortDescription => name;

  PropertyElement(Map json, Element parent) : super(json, parent),
    returnType = jsonDeserializeReference(json['ref']);

  String get longDescription {
    var sb = new StringBuffer();
    if (returnType != null) {
      sb..add(returnType.shortDescription)..add(" ");
    }
    sb.add("get $name");
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
      sb..add(returnType.shortDescription)..add(" ");
    }
    sb.add(name);
    return sb.toString();
  }

  /**
   * Group variables and properties together in the UI as they are
   * interchangeable as far as users are concerned.
   */
  String get uiKind => 'property';

  VariableElement(Map json, Element parent) : super(json, parent),
    returnType = jsonDeserializeReference(json['ref']),
    isFinal = json['isFinal'];

  void traverse(void callback(Element)) {
    callback(this);
  }
}

/**
 * Element describing a constructor.
 */
class ConstructorElement extends MethodLikeElement {
  ConstructorElement(json, Element parent) : super(json, parent);

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

  String get kindTitle => KIND_TITLES[kind];

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
