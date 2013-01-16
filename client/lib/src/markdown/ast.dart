// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of markdown;

// TODO(jacobr): remove the Markdown prefixes from these class names once
// http://code.google.com/p/dart/issues/detail?id=7704 is fixed.

/// Base class for any AST item. Roughly corresponds to Node in the DOM. Will
/// be either an [MarkdownElement] or [MarkdownText].
abstract class MarkdownNode {
  void accept(NodeVisitor visitor);
}

/// A named tag that can contain other nodes.
class MarkdownElement implements MarkdownNode {
  final String tag;
  final List<MarkdownNode> children;
  final Map<String, String> attributes;

  MarkdownElement(this.tag, this.children)
    : attributes = <String, String>{};

  MarkdownElement.empty(this.tag)
    : children = null,
      attributes = <String, String>{};

  MarkdownElement.withTag(this.tag)
    : children = [],
      attributes = <String, String>{};

  MarkdownElement.text(this.tag, String text)
    : children = [new MarkdownText(text)],
      attributes = <String, String>{};

  bool get isEmpty => children == null;

  void accept(NodeVisitor visitor) {
    if (visitor.visitElementBefore(this)) {
      for (final child in children) child.accept(visitor);
      visitor.visitElementAfter(this);
    }
  }
}

/// A plain text element.
class MarkdownText implements MarkdownNode {
  final String text;
  MarkdownText(this.text);

  void accept(NodeVisitor visitor) => visitor.visitText(this);
}

/// Visitor pattern for the AST. Renderers or other AST transformers should
/// implement this.
abstract class NodeVisitor {
  /// Called when a Text node has been reached.
  void visitText(MarkdownText text);

  /// Called when an Element has been reached, before its children have been
  /// visited. Return `false` to skip its children.
  bool visitElementBefore(MarkdownElement element);

  /// Called when an Element has been reached, after its children have been
  /// visited. Will not be called if [visitElementBefore] returns `false`.
  void visitElementAfter(MarkdownElement element);
}
