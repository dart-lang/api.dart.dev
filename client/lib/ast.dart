// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * AST describing all information about Dart libraries required to render
 * Dart documentation.
 */
library ast;

import 'dart:json';
import 'package:web_ui/safe_html.dart';
import 'markdown.dart' as md;

/**
 * Top level data model for the app.
 * Mapping from String ids to [LibraryElement] objects describing all currently
 * loaded libraries. All code must be written to work properly if more libraries
 * are loaded incrementally.
 */
Map<String, LibraryElement> libraries = <LibraryElement>{};

/**
 * Children of a library are shown in the UI grouped by type sorted in the order
 * specified by this list.
 */
List<String> LIBRARY_ITEMS = ['variable', 'property', 'method', 'class',
                              'exception', 'typedef'];
/**
 * Children of a class are shown in the UI grouped by type sorted in the order
 * specified by this list.
 */
List<String> CLASS_ITEMS = ['constructor', 'variable', 'property', 'method',
                            'operator'];
// TODO(jacobr): add package kinds?

// TODO(jacobr): i18n
/**
 * Pretty names for the various kinds displayed.
 */
final KIND_TITLES = {
    'property': 'Properties',
    'variable': 'Variables',
    'method': 'Functions',
    'constructor': 'Constructors',
    'class': 'Classes',
    'operator': 'Operators',
    'typedef': 'Typedefs',
    'exception': 'Exceptions'
};

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
      return name;
    } else {
      var params = Strings.join(
          arguments.map((param) => param.shortDescription), ', ');
      return '$name<$params>';
    }
  }
}

void loadLibraryJson(String json) {
  for (var libraryJson in JSON.parse(json)) {
    var library = new LibraryElement(libraryJson, null);
    libraries[library.id] = library;
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
  Element current = lookupLibrary(parts.first);
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
_traverseWorld(void callback(Element)) {
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
  void traverse(void callback(Element)) {
    callback(this);
    for (var child in children) {
      callback(child);
    }
  }

  /**
   * Uri containing the source code for the definition of the element.
   */
  String get uri => _uri != null ? _uri : (parent != null ? parent.uri : null);

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
    children.some((child) => child.hasReference(referenceId));

  /** Returns all [Element]s that reference this [Element]. */
  List<Element> get references {
    if (_references == null) {
      _references = <Element>[];
      _traverseWorld((element) {
        if (element.hasReference(refId)) {
          _references.add(element);
        }
      });
    }
    return _references;
  }

  /** Path from the root of the tree to this [Element]. */
  List<Element> get path {
    /*
    if (parent == null) {
      return <Element>[this];
    } else {
      return parent.path..add(this);
    }*/
    // TODO(jacobr): replace this code with:
    return (parent == null) ? <Element>[this] : parent.path..add(this);
    // once http://code.google.com/p/dart/issues/detail?id=7665 is fixed.
  }

  List<Element> get typeParameters {
    if (_typeParameters == null) {
      _typeParameters = _filterByKind('typeparam');
    }
    return _typeParameters;
  }

  /**
   * [SafeHtml] for the comment associated with this [Element] generated from
   * the markdow comment associated with the element.
   */
  SafeHtml get commentHtml {
    if (_commentHtml == null) {
      _commentHtml = _markdownToSafeHtml(comment);
    }
    return _commentHtml;
  }

  /**
   * Short description appropriate for displaying in a tree control or other
   * situtation where a short description is required.
   */
  String get shortDescription {
    if (typeParameters.isEmpty) {
      return name;
    } else {
      var params = Strings.join(
          typeParameters.map((param) => param.shortDescription),
          ', ');
      return '$name<$params>';
    }
  }

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
  List<ElementBlock> _createElementBlocks(List<String> desiredKinds) {
    var blockMap = new Map<String, List<Element>>();
    for (var child in children) {
      if (desiredKinds.contains(child.uiKind)) {
        blockMap.putIfAbsent(child.uiKind, () => <Element>[]).add(child);
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
      children.filter((child) => child.kind == kind);

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
  List<ElementBlock> _childBlocks;

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
  List<ElementBlock> get childBlocks {
    if (_childBlocks == null) {
      _childBlocks = _createElementBlocks(LIBRARY_ITEMS);
    }
    return _childBlocks;
  }
}

/**
 * [Element] describing a Dart class.
 */
class ClassElement extends Element {

  /** Members of the class grouped into logical blocks. */
  List<ElementBlock> _childBlocks;

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

  /** Returns all superclasses of this class. */
  List<ClassElement> get superclasses {
    if (_superclasses == null) {
      _superclasses = <ClassElement>[];
      addSuperclasses(clazz) {
        if (clazz.superclass != null) {
          var superclassElement = lookupReferenceId(clazz.superclass.refId);
          addSuperclasses(superclassElement);
          _superclasses.add(superclassElement);
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
  List<ElementBlock> get childBlocks {
    if (_childBlocks == null) _childBlocks = _createElementBlocks(CLASS_ITEMS);
    return _childBlocks;
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

  bool hasReference(String referenceId) {
    if (super.hasReference(referenceId)) return true;
    return returnType != null && returnType.refId == referenceId;
  }

  String get uiKind => isSetter ? 'property' : kind;

  /**
   * Returns a plain text short description of the method suitable for rendering
   * in a tree control or other case where a short method description is
   * required.
   */
  String get shortDescription {
    if (isSetter) {
      var sb = new StringBuffer('${name.substring(0, name.length - 1)}');
      if (!parameters.isEmpty && parameters.first != null
          && parameters.first.type != null) {
        sb..add(' ')..add(parameters.first.type.name);
      }
      return sb.toString();
    }
    return '$name(${Strings.join(parameters.map(
        (arg) => arg.type != null ? arg.type.name : ''), ', ')})';
  }

  Reference get returnType;
  List<Element> _parameters;

  /**
   * Returns a list of the parameters of the Method.
   */
  List<Element> get parameters {
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
      returnType = jsonDeserializeReference(json['returnType']);
}

/**
 * Element describing a property getter.
 */
class PropertyElement extends MethodLikeElement {
  final Reference returnType;

  String get shortDescription => name;

  PropertyElement(Map json, Element parent) : super(json, parent),
    returnType = jsonDeserializeReference(json['ref']);
}

/**
 * Element describing a variable.
 */
class VariableElement extends MethodLikeElement {
  final Reference returnType;
  /** Whether this variable is final. */
  final bool isFinal;

  String get shortDescription => name;

  VariableElement(Map json, Element parent) : super(json, parent),
    returnType = jsonDeserializeReference(json['ref']),
    isFinal = json['isFinal'];
}

/**
 * Element describing a constructor.
 */
class ConstructorElement extends MethodLikeElement {
  ConstructorElement(json, Element parent) : super(json, parent);

  Reference get returnType => null;
}

/**
 * Block of elements to render summary documentation for all elements that share
 * the same kind.
 *
 * For example, all properties, all functions, or all constructors.
 */
class ElementBlock {
  String kind;
  List<Element> elements;

  ElementBlock(this.kind, this.elements);

  String get kindTitle => KIND_TITLES[kind];
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
