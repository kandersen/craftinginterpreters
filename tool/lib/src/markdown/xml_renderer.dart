import 'package:markdown/markdown.dart';

final _imagePathPattern = RegExp(r'"([^"]+.png)"');

class XmlRenderer implements NodeVisitor {
  /// The list of paragraph-level tags.
  final List<_Paragraph> _paragraphs = [];

  /// Whether we need to create a new paragraph before appending the next text.
  bool _pendingParagraph = true;

  /// The nested stack of current inline tags.
  final List<_Inline> _inlineStack = [];

  /// The stack tracking where we are in the document.
  _Context _context = _Context("main");

  String render(List<Node> nodes) {
    for (final node in nodes) {
      node.accept(this);
    }

    var buffer = StringBuffer();
    buffer.writeln("<chapter>");

    // var i = 0;
    // for (var paragraph in _paragraphs) {
    //   var text = paragraph.contents.map((i) => i.text).join();
    //   if (text.length > 40) text = text.substring(0, 40);
    //   print("${paragraph.context} :: $text");
    //   // if (i++ > 10) break;
    // }

    _Paragraph previousMain;
    _Paragraph previousAside;

    for (var paragraph in _paragraphs) {
      if (paragraph.context.has("aside")) {
        paragraph.prettyPrint(buffer, previousAside);
        previousAside = paragraph;
      } else {
        paragraph.prettyPrint(buffer, previousMain);
        previousMain = paragraph;

        // Reached the end of an aside.
        previousAside = null;
      }
    }

    buffer.writeln("</chapter>");
    return buffer.toString();
  }

  void visitText(Text node) {
    var text = node.text;

    if (text.isEmpty) return;

    text = text
        .replaceAll("&eacute;", "&#233;")
        .replaceAll("&ensp;", "&#8194;")
        .replaceAll("&ldquo;", "&#8220;")
        .replaceAll("&nbsp;", "&#160;")
        .replaceAll("&rdquo;", "&#8221;")
        .replaceAll("&rsquo;", "&#8217;")
        .replaceAll("&rarr;", "&#8594;")
        .replaceAll("&sect;", "&#167;")
        .replaceAll("&thinsp;", "&#8201;")
        .replaceAll("&times;", "&#215;")
        .replaceAll("<br>", "<br/>");

    // Discard the challenge and design note divs.
    if (text.startsWith("<div") || text.startsWith("</div>")) return;

    // Convert image tags to just their paths.
    if (text.startsWith("<img")) {
      var imagePath = _imagePathPattern.firstMatch(text)[1];

      // The GC chapter has a couple of tiny inline images that happen to be in
      // an unordered list. Don't create paragraphs for them.
      var isInline = _context.has("unordered");

      // Put main column images in their own paragraph.
      if (!isInline) _push("image");
      _addText(imagePath);
      if (!isInline) _pop();
      return;
    }

    // Include code snippet XML as-is.
    if (text.startsWith("<location-file>") ||
        text.startsWith("<interpreter>")) {
      _push("xml");
      _addText(text);
      _pop();
      return;
    }

    // Since aside tags appear in the Markdown as literal HTML, they are parsed
    // as text, not Markdown elements.
    if (text.startsWith("<aside")) {
      _push("aside");
      return;
    }

    if (text.startsWith("</aside>")) {
      _pop();
      return;
    }

    if (text.trimLeft().startsWith("<cite>")) {
      _push("xml");
      _addText(text.trimLeft());
    } else if (_inlineStack.isNotEmpty) {
      // We're in an inline tag, so add it to that.
      _inlineStack.last.text += text;
    } else {
      _addText(text);
    }

    if (text.endsWith("</cite>")) _pop();
  }

  bool visitElementBefore(Element element) {
    switch (element.tag) {
      case "p":
        _resetParagraph();
        break;

      case "blockquote":
        _push("quote");
        break;

      case "h2":
        var text = element.textContent;
        if (text == "Challenges") {
          _context = _Context("challenges");
        } else if (text.contains("Design Note")) {
          _context = _Context("design");
        }
        _push("heading");
        break;

      case "h3":
        _push("subheading");
        break;

      case "ol":
        _push("ordered");

        // Immediately push a subcontext to mark the first list item.
        _push("first");
        break;

      case "pre":
        _push("pre");
        break;

      case "ul":
        _push("unordered");

        // Immediately push a subcontext to mark the first list item.
        _push("first");
        break;

      case "li":
        // If we're on the first item, discard it and replace it with the next
        // item. The first item restarts numbering but later ones don't.
        if (_context.name != "first") _push("item");
        break;

      case "a":
        // TODO: What do we want to do with links? Highlight them somehow so
        // that I decide if the surrounding text needs tweaking?
        break;

      case "code":
      case "em":
      case "small":
      case "strong":
        // Inline tags.

        // If we're in an inline tags already, flatten them by emitting inline
        // segments for any text they have. Leave them on the stack so that
        // they get resumed when the nested inline tags end.
        var tagParts = [element.tag];
        for (var i = 0; i < _inlineStack.length; i++) {
          var inline = _inlineStack[i];
          if (inline.text.isNotEmpty) {
            _addInline(inline);
            _inlineStack[i] = _Inline(inline.tag);
          }

          tagParts.add(inline.tag);
        }

        tagParts.sort();
        // Make a tag name that includes all nested tags. We'll define separate
        // styles for each combination.
        _inlineStack.add(_Inline(tagParts.join("-")));
        break;

      default:
        print("Unexpected open tag ${element.tag}.");
    }

    return !element.isEmpty;
  }

  void visitElementAfter(Element element) {
    switch (element.tag) {
      case "blockquote":
      case "h2":
      case "h3":
      case "pre":
        _pop();
        break;

      case "ol":
      case "ul":
        // If we still have a context for the item, it means we have a Markdown
        // list with no paragraph tags inside the items. There are a couple of
        // those in the book.
        if (_context.name == "first" || _context.name == "item") _pop();

        // Pop the list itself.
        _pop();
        break;

      case "a":
        // Nothing to do.
        break;

      case "li":
      case "p":
        // The first paragraph in each list item has a special style so that
        // apply the bullet or number. Later paragraphs in the same list item
        // do not.

        // We match both <p> and <li> so that lists without paragraphs inside
        // don't leave lingering item contexts.
        if (_context.name == "first" || _context.name == "item") _pop();
        break;

      case "code":
      case "em":
      case "small":
      case "strong":
        // Inline tags.
        _addInline(_inlineStack.removeLast());
        break;

      default:
        print("Unexpected close tag ${element.tag}.");
    }
  }

  void _push(String name) {
    _context = _Context(name, _context);
    _resetParagraph();
  }

  void _pop() {
    _context = _context.parent;
    _resetParagraph();
  }

  void _addText(String text) {
    _flushParagraph();

    // Discard any leading whitespace at the beginning of list items.
    var paragraph = _paragraphs.last;
    if (paragraph.contents.isEmpty &&
        (_context.has("ordered") || _context.has("unordered"))) {
      text = text.trimLeft();
    }

    paragraph.contents.add(_Inline(null, text));
  }

  void _addInline(_Inline inline) {
    _flushParagraph();
    _paragraphs.last.contents.add(inline);
  }

  void _resetParagraph() {
    _pendingParagraph = true;
  }

  void _flushParagraph() {
    if (!_pendingParagraph) return;
    _paragraphs.add(_Paragraph(_context));
    _pendingParagraph = false;
  }
}

class _Context {
  final String name;
  final _Context parent;

  _Context(this.name, [this.parent]);

  /// Whether any of the contexts in this chain are [name].
  bool has(String name) {
    var context = this;
    while (context != null) {
      if (context.name == name) return true;
      context = context.parent;
    }

    return false;
  }

  /// Whether [parent] has [name].
  bool isIn(String name) => parent != null && parent.has(name);

  /// How many levels of list nesting this context contains.
  int get listDepth {
    var depth = 0;

    for (var context = this; context != null; context = context.parent) {
      if (context.name == "ordered" || context.name == "unordered") {
        depth++;
      }
    }

    return depth;
  }

  String get paragraphTag {
    if (name == "main") return "p";
    if (name == "challenges") return "challenges-p";
    if (name == "design") return "design-p";
    if (name == "aside") return "aside";
    if (name == "xml") return "xml";

    if (isIn("aside")) return "aside-$name";

    var tag = name;
    var depth = listDepth;
    if (depth > 2) print("Unexpected deep list nesting $this.");

    if (name == "first" || name == "item") {
      tag = "${parent.name}-$name";
      if (depth > 1) tag = "sublist-$tag";
    } else if (name == "ordered" || name == "unordered") {
      tag = "list-p";
      if (depth > 1) tag = "sublist-$tag";
    } else if (depth > 1) {
      tag = "sublist-$tag";
    } else if (depth > 0) {
      tag = "list-$tag";
    }

    if (isIn("challenges")) tag = "challenges-$tag";
    if (isIn("design")) tag = "design-$tag";
    return tag;
  }

  /// The prefix to apply to inline tags within this context or the empty string
  /// it none should be added.
  String get inlinePrefix {
    if (has("aside")) return "aside";
    if (has("challenges")) return "challenges";
    if (has("design")) return "design";
    if (has("quote")) return "quote";

    return "";
  }

  String toString() {
    if (parent == null) return name;
    return "$parent > $name";
  }
}

/// A paragraph-level tag that contains text and inline tags.
class _Paragraph {
  final _Context context;

  final List<_Inline> contents = [];

  _Paragraph(this.context);

  bool _isNext(String tag, String previousTag) {
    const nextTags = {
      "aside",
      "challenges-p",
      "challenges-list-p",
      "design-p",
      "design-list-p",
      "list-p",
      "p"
    };

    if (tag == previousTag) return nextTags.contains(tag);

    // The paragraph after a bullet item is also a next.
    if (tag.endsWith("list-p")) {
      // This includes both "unordered" and "ordered", tags that start with
      // "challenges" or "design", and ones that end with "first" or "item".
      return previousTag.contains("ordered-");
    }

    return false;
  }

  void prettyPrint(StringBuffer buffer, _Paragraph previous) {
    var tag = context.paragraphTag;

    if (previous != null && _isNext(tag, previous.context.paragraphTag)) {
      tag += "-next";
    }

    if (tag != "xml") buffer.write("<$tag>");

    for (var inline in contents) {
      inline.prettyPrint(buffer, context);
    }

    if (tag != "xml") buffer.write("</$tag>");
    buffer.writeln();
  }
}

/// An inline tag or plain text.
class _Inline {
  /// The tag name if this is an inline tag or `null` if it is text.
  final String tag;

  String text;

  _Inline(this.tag, [this.text = ""]);

  bool get isText => tag == null;

  void prettyPrint(StringBuffer buffer, _Context context) {
    if (tag == null) {
      buffer.write(text);
      return;
    }

    var fullTag = tag;
    var prefix = context.inlinePrefix;
    if (prefix != "") fullTag = "$prefix-$fullTag";

    buffer.write("<$fullTag>$text</$fullTag>");
  }
}
