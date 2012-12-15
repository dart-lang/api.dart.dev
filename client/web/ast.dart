library ast;

import 'package:web_ui/safe_html.dart';
import 'markdown.dart' as md;

/**
 * Top level data model for the app.
 * Mapping from String ids to [LibraryElement] objects describing all currently
 * loaded libraries. All code must be written to work properly if more libraries
 * are loaded incrementally.
 */
Map<String, LibraryElement> libraries = <LibraryElement>{};

List<String> LIBRARY_KINDS = ['variable', 'property', 'method', 'class', 'exception', 'typedef'];
List<String> CLASS_KINDS = ['constructor', 'variable', 'property', 'method', 'operator'];
// TODO(jacobr): add package kinds?

// TODO(jacobr): i18n
/**
 * Pretty names for the various kinds displayed.
 */
final KIND_TITLES = {'property': 'Properties',
                     'variable': 'Variables',
                     'method': 'Functions',
                     'constructor': 'Constructors',
                     'class': 'Classes',
                     'operator': 'Operators',
                     'typedef': 'Typedefs',
                     'exception': 'Exceptions'
};

/**
 * Block of elements to render summary documentation for that all share the
 * same kind.
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
 * Deserializes JSON into [Element] or [Reference] objects.
 */
Element jsonDeserialize(Map json, Element parent) {
  if (json == null) return null;
  if (!json.containsKey('kind')) {
    throw "Unable to deserialize $json";
  }

  switch (json['kind']) {
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

List<Element> jsonDeserializeArray(List json, Element parent) {
  var ret = <Element>[];
  if (json != null) {
    for (Map elementJson in json) {
      ret.add(jsonDeserialize(elementJson, parent));
    }
  }
  return ret;
}

List<Reference> jsonDeserializeReferenceArray(List json) {
  var ret = <Reference>[];
  if (json != null) {
    for (Map referenceJson in json) {
      ret.add(new Reference(referenceJson));
    }
  }
  return ret;
}

/**
 * Reference to an [Element].
 */
class Reference {
  final String refId;
  final String name;
  Reference(Map json) :
    name = json['name'],
    refId = json['refId'];
}

/**
 * Lookup a library based on the [libraryId].
 *
 * If the library cannot be found, a stub dummy [Library] will be returned.
 */
LibraryElement lookupLibrary(String libraryId) {
  var library = libraries[libraryId];
  if (library == null) {
    library = new LibraryElement.stub(libraryId, null);
  }
  return library;
}

/**
 * Resolve the [Element] matching the [referenceId].
 *
 * If the Element cannot be found, a stub dummy [Element] will be returned.
 */
Element lookupReferenceId(String referenceId) {
  var parts = referenceId.split(new RegExp('/'));
  Element current = lookupLibrary(parts.first);
  var result = <Element>[current];
  for (var i = 1; i < parts.length; i++) {
    var id = parts[i];
    var next = null;
    for (var child in current.children) {
      if (child.id == id) {
        next = child;
        break;
      }
    }
    if (next == null) {
      next = new Element.stub(id, current);
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

// TODO(jacobr): remove this method when templates handle safe HTML containing
SafeHtml _markdownToSafeHtml(String text) {
  // We currently have to insert an extra span for now because of
  // https://github.com/dart-lang/dart-web-components/issues/212
  return new SafeHtml.unsafe(text != null && !text.isEmpty ?
        '<span>${md.markdownToHtml(text)}</span>' : '<span><span>');
}

/**
 * Specifies the order elements should appear in the UI.
 */
int elementUiOrder(Element a, Element b) {
  if (a.isPrivate != b.isPrivate) {
    return a.isPrivate == true ? 1 : -1;
  }
  return a.name.compareTo(b.name);
}

/**
 * Base class for all elements in the AST.
 */
class Element {
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

  final String _uri;
  final String _line;

  /** Children of the node. */
  List<Element> children;

  /** Whether the [Element] is currently being loaded. */
  final bool loading;

  String _refId;

  Map _members;
  SafeHtml _commentHtml;
  List<Element> _references;

  Element(Map json, this.parent) :
    name = json['name'],
    rawKind = json['kind'],
    id = json['id'],
    comment = json['comment'],
    isPrivate = json['isPrivate'],
    _uri = json['uri'],
    _line = json['line'],
    loading = false {
    children = jsonDeserializeArray(json['children'], this);
  }

  /**
   * Returns a kind name that make sense for the UI rather than the AST
   * kinds.  For example, setters are considered properties instead of
   * methods.
   */
  String get uiKind => kind;

  /** Invoke [callback] on this [Element] and all descendants. */
  void traverse(void callback(Element)) {
    callback(this);
    for (var child in children) {
      callback(child);
    }
  }

  /**
   * Uri containing the definition of the element.
   */
  String get uri {
    Element current = this;
    while (current != null) {
      if (current._uri != null) return current._uri;
      current = current.parent;
    }
    return null;
  }

  /**
   * Line in the original source file that starts the definition of the element.
   */
  String get line {
    Element current = this;
    while (current != null) {
      if (current._line != null) return current._line;
      current = current.parent;
    }
    return null;
  }

  Element.stub(this.id, this.parent) :
    name = '???', // TODO(jacobr): remove/add
    _uri = null,
    _line = null,
    comment = null,
    rawKind = null,
    children = <Element>[],
    isPrivate = null,
    loading = true;

  /**
   *  Globally unique identifier for this element.
   */
  String get refId {
    if (_refId == null) {
       if (parent == null) {
         _refId = id;
       } else {
         _refId = '${parent.refId}/$id';
       }
    }
    return _refId;
  }

  /**
   * Whether this [Element] references the specified [referenceId].
   */
  bool hasReference(String referenceId) {
    for (var child in children) {
      if (child.hasReference(referenceId)) {
        return true;
      }
    }
    return false;
  }

  /** Returns all [Element]s that reference this [Element]. */
  List<Element> get references {
    if (_references == null) {
      _references = <Element>[];
      // TODO(jacobr): change to filterWorld and tweak meaning.
      _traverseWorld((element) {
        if (element.hasReference(refId)) {
          _references.add(element);
        }
      });
    }
    return _references;
  }

  // TODO(jacobr): write without recursion.
  /**
   * Path from this [Element] to the root of the tree starting at the root.
   */
  List<Element> get path {
    if (parent == null) {
      return <Element>[this];
    } else {
      return parent.path..add(this);
    }
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
  String get shortDescription => name;

  /** Possibly normalized representation of the node kind. */
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
        blocks.add(new ElementBlock(kind, elements..sort(elementUiOrder)));
      }
    }
    return blocks;
  }

  List<Element> _filterByKind(String kind) =>
      children.filter((child) => child.kind == kind);

  Map<String, Element> _mapForKind(String kind) {
    Map ret = {};
    if (children != null) {
      for (var child in children) {
        if (child.kind == kind) {
          ret[child.id] = child;
        }
      }
    }
    return ret;
  }

  Map<String, Element> _mapForKinds(Map<String, Element> kinds) {
    Map ret = {};
    if (children != null) {
      for (var child in children) {
        if (kinds.containsKey(child.kind)) {
          ret[child.id] = child;
        }
      }
    }
    return ret;
  }

  Map<String, Element> get members {
    if (_members == null) {
      // TODO(jacobr): include properties???!?
      _members = _mapForKinds({'method': true, 'property' : true});
    }
    return _members;
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
  LibraryElement.stub(String id, Element parent) : super.stub(id, parent);

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
      _sortedClasses = []..addAll(classes.values)..sort(elementUiOrder);
    }
    return _sortedClasses;
  }

  /**
   * Returns all blocks of elements that should be rendered by UI summarizing
   * the Library.
   */
  List<ElementBlock> get childBlocks {
    if (_childBlocks == null) _childBlocks = _createElementBlocks(LIBRARY_KINDS);
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

  List<ClassElement> _superclasses;
  List<ClassElement> _subclasses;

  ClassElement(Map json, Element parent)
    : super(json, parent),
      interfaces = jsonDeserializeReferenceArray(json['interfaces']),
      superclass = jsonDeserializeReference(json['superclass']);

  ClassElement.stub(String id, Element parent)
    : super.stub(id, parent),
      interfaces = [],
      superclass = null;

  /** Returns all superclasses of this class. */
  List<ClassElement> get superclasses {
    if (_superclasses == null) {
      _superclasses = <ClassElement>[];
      addSuperclasses(clazz) {
        if (clazz.superclass != null) {
          ClassElement superclassElement =
              lookupReferenceId(clazz.superclass.refId);
          addSuperclasses(superclassElement);
          _superclasses.add(superclassElement);
        }
      }
      addSuperclasses(this);
    }
    return _superclasses;
  }

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
    if (_childBlocks == null) _childBlocks = _createElementBlocks(CLASS_KINDS);
    return _childBlocks;
  }
}

class TypedefElement extends Element {
  final Reference returnType;
  List<ParameterElement> _parameters;

  TypedefElement(Map json, Element parent) : super(json, parent),
      returnType = jsonDeserializeReference(json['returnType']);

  /**
   * Returns a list of the parameters of the typedef.
   */
  List<ParameterElement> get parameters {
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
abstract class MethodElementBase extends Element {

  final bool isOperator;
  final bool isStatic;
  final bool isSetter;

  MethodElementBase(Map json, Element parent)
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
    if (isSetter == true) {
      var sb = new StringBuffer('${name.substring(0, name.length-1)}');
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

  // For UI purposes we want to treat operators as their own kind.
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

  bool hasReference(String referenceId) {
    if (super.hasReference(referenceId)) return true;
    return upperBound != null && upperBound.refId == referenceId;
  }
}

class MethodElement extends MethodElementBase {

  final Reference returnType;

  MethodElement(Map json, Element parent) : super(json, parent),
      returnType = jsonDeserializeReference(json['returnType']);
}

class PropertyElement extends MethodElementBase {
  final Reference returnType;

  String get shortDescription => name;

  PropertyElement(Map json, Element parent) : super(json, parent),
    returnType = jsonDeserializeReference(json['ref']);
}

class VariableElement extends MethodElementBase {
  final Reference returnType;
  /** Whether this variable is final. */
  final bool isFinal;

  String get shortDescription => name;

  VariableElement(Map json, Element parent) : super(json, parent),
    returnType = jsonDeserializeReference(json['ref']),
    isFinal = json['isFinal'];
}

class ConstructorElement extends MethodElementBase {
  ConstructorElement(json, Element parent) : super(json, parent);

  Reference get returnType => null;
}
