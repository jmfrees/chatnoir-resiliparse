# Copyright 2021 Janek Bevendorff
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# distutils: language = c++

from cython.operator cimport dereference as deref, preincrement as preinc, predecrement as predec
from libc.stdint cimport uint32_t
from libcpp.set cimport set as stl_set
from libc.string cimport memcpy
from libcpp.memory cimport make_shared, shared_ptr
from libcpp.string cimport string, to_string
from libcpp.vector cimport vector

from resiliparse.parse.encoding import bytes_to_str
from resiliparse_common.string_util cimport rstrip_str, strip_str
from resiliparse_inc.cctype cimport isspace
from resiliparse.parse.html cimport *
from resiliparse_inc.lexbor cimport *
from resiliparse_inc.re2 cimport Options as RE2Options, RE2Stack as RE2, StringPiece, PartialMatch


cdef extern from * nogil:
    """
    struct ExtractOpts {
        bool preserve_formatting = true;
        bool list_bullets = true;
        bool links = false;
        bool alt_texts = true;
        bool form_fields = false;
        bool noscript = false;
    };

    struct ExtractContext {
        lxb_dom_node_t* root_node = NULL;
        lxb_dom_node_t* node = NULL;
        size_t depth = 0;
        ExtractOpts opts;
    };

    struct ExtractNode {
        lxb_dom_node_t* reference_node = NULL;
        lxb_tag_id_t tag_id = LXB_TAG__UNDEF;
        size_t depth = 0;
        bool space_after = false;
        bool collapse_margins = true;
        bool is_big_block = false;
        bool is_pre = false;
        bool is_end_tag = false;
        std::shared_ptr<std::string> text_contents = NULL;
    };
    """
    cdef struct ExtractOpts:
        bint preserve_formatting
        bint list_bullets
        bint links
        bint alt_texts
        bint form_fields
        bint noscript

    cdef struct ExtractContext:
        lxb_dom_node_t * root_node
        lxb_dom_node_t * node
        size_t depth
        ExtractOpts opts

    cdef struct ExtractNode:
        lxb_dom_node_t* reference_node
        lxb_tag_id_t tag_id
        size_t depth
        bint space_after
        bint collapse_margins
        bint is_big_block
        bint is_pre
        bint is_end_tag
        shared_ptr[string] text_contents


cdef string _get_collapsed_string(const string_view& input_str) nogil:
    """
    Collapse newlines and consecutive white space in a string to single spaces.
    Takes into account previously extracted text from ``ctx.text``.
    """
    if input_str.empty():
        return string()

    cdef string element_text
    element_text.reserve(input_str.size())
    for i in range(input_str.size()):
        if isspace(input_str[i]):
            if element_text.empty() or not isspace(element_text.back()):
                element_text.push_back(b' ')
        else:
            element_text.push_back(input_str[i])

    if element_text.capacity() > element_text.size() // 2:
        element_text.reserve(element_text.size())    # Shrink to fit
    return element_text


cdef string LIST_BULLET = <const char*>b'\xe2\x80\xa2'


cdef inline void _ensure_text_contents(vector[shared_ptr[ExtractNode]]& extract_nodes) nogil:
    if not deref(extract_nodes.back()).text_contents:
        deref(extract_nodes.back()).text_contents = make_shared[string]()


cdef inline void _ensure_space(string& in_str, char space_char) nogil:
    if in_str.empty() or not isspace(in_str.back()):
        in_str.push_back(space_char)


cdef void _extract_cb(vector[shared_ptr[ExtractNode]]& extract_nodes, ExtractContext& ctx, bint is_end_tag) nogil:
    cdef shared_ptr[ExtractNode] last_node_shared
    cdef ExtractNode* last_node = NULL
    cdef bint is_block = ctx.node.type == LXB_DOM_NODE_TYPE_ELEMENT and is_block_element(ctx.node.local_name)
    if not extract_nodes.empty():
        last_node = extract_nodes.back().get()

    if not last_node or is_block or ctx.depth < last_node.depth or ctx.node.local_name == LXB_TAG_TEXTAREA:
        last_node_shared = make_shared[ExtractNode]()
        extract_nodes.push_back(last_node_shared)
        last_node = extract_nodes.back().get()
        last_node.reference_node = ctx.node
        last_node.depth = ctx.depth
        last_node.is_big_block = ctx.node.local_name in [LXB_TAG_P, LXB_TAG_H1, LXB_TAG_H2, LXB_TAG_H3, LXB_TAG_H4]
        last_node.tag_id = ctx.node.local_name
        last_node.is_pre = not is_end_tag and ctx.node.local_name in [LXB_TAG_PRE, LXB_TAG_TEXTAREA]
        last_node.is_end_tag = is_end_tag

    cdef lxb_dom_character_data_t* char_data = NULL
    cdef string element_text
    cdef string_view element_text_sv

    if ctx.node.type == LXB_DOM_NODE_TYPE_TEXT:
        _ensure_text_contents(extract_nodes)
        node_char_data = <lxb_dom_character_data_t*>ctx.node
        element_text_sv = string_view(<const char*>node_char_data.data.data, node_char_data.data.length)
        if last_node.is_pre and ctx.opts.preserve_formatting:
            deref(last_node.text_contents).append(<string>element_text_sv)
        else:
            element_text = _get_collapsed_string(element_text_sv)
            element_text_sv = <string_view>element_text
            if deref(last_node.text_contents).empty() or isspace(deref(last_node.text_contents).back()):
                while not element_text_sv.empty() and isspace(element_text_sv.front()):
                    element_text_sv.remove_prefix(1)
            if not element_text_sv.empty():
                deref(last_node.text_contents).append(<string>element_text_sv)

    elif ctx.node.type != LXB_DOM_NODE_TYPE_ELEMENT:
        return

    elif ctx.node.local_name in [LXB_TAG_BR, LXB_TAG_HR]:
        _ensure_text_contents(extract_nodes)
        last_node.collapse_margins = False

    elif ctx.opts.links and is_end_tag and ctx.node.local_name == LXB_TAG_A:
        element_text_sv = <string>get_node_attr_sv(ctx.node, b'href')
        if not element_text_sv.empty():
            element_text.append(b' (')
            element_text.append(<string> element_text_sv)
            element_text.append(b') ')
            _ensure_text_contents(extract_nodes)
            deref(last_node.text_contents).append(element_text)

    elif ctx.opts.alt_texts and ctx.node.local_name in [LXB_TAG_IMG, LXB_TAG_AREA]:
        _ensure_text_contents(extract_nodes)
        element_text_sv = get_node_attr_sv(ctx.node, b'alt')
        if not element_text_sv.empty():
            deref(last_node.text_contents).append(<string>element_text_sv)

    elif ctx.opts.form_fields and ctx.node.local_name in [LXB_TAG_TEXTAREA, LXB_TAG_BUTTON]:
        if not is_end_tag:
            element_text.append(b'[ ')
        else:
            element_text.append(b' ]')
        _ensure_text_contents(extract_nodes)
        deref(last_node.text_contents).append(element_text)
        return

    elif ctx.opts.form_fields and ctx.node.local_name == LXB_TAG_INPUT:
        element_text_sv = get_node_attr_sv(ctx.node, b'type')
        if element_text_sv.empty() or element_text_sv not in \
                [b'checkbox', b'color', b'file', b'hidden', b'radio', b'reset']:
            element_text_sv = get_node_attr_sv(ctx.node, b'value')
            if element_text_sv.empty():
                element_text_sv = get_node_attr_sv(ctx.node, b'placeholder')
            if not element_text_sv.empty():
                _ensure_text_contents(extract_nodes)
                element_text.append(b'[ ')
                element_text.append(<string> element_text_sv)
                element_text.append(b' ]')
                _ensure_text_contents(extract_nodes)
                deref(last_node.text_contents).append(element_text)


cdef inline string _indent_newlines(const string& element_text, size_t depth) nogil:
    cdef string indent = string(2 * depth, <char>b' ')
    cdef string tmp_text
    tmp_text.reserve(element_text.size() + 10 * indent.size())
    for i in range(element_text.size()):
        tmp_text.push_back(element_text[i])
        if element_text[i] == b'\n':
            tmp_text.append(indent)

    return tmp_text


cdef inline void _make_margin(const ExtractNode* node, const ExtractOpts& opts, bint bullet_deferred,
                              string& output) nogil:
    if opts.preserve_formatting:
        if not node.collapse_margins or (not output.empty() and output.back() != b'\n'):
            output.push_back(<char>b'\n')
        if node.is_big_block and not bullet_deferred and output.size() >= 2 and \
                output[output.size() - 2] != b'\n':
            output.push_back(<char>b'\n')
    elif not output.empty() and output.back() != b' ':
        output.push_back(<char>b' ')


cdef string _serialize_extract_nodes(vector[shared_ptr[ExtractNode]]& extract_nodes, const ExtractOpts& opts) nogil:
    cdef size_t i
    cdef string output
    cdef string element_text
    cdef ExtractNode* current_node = NULL
    cdef bint bullet_deferred = False
    cdef size_t list_depth = 0
    cdef vector[size_t] list_numbering
    cdef string list_item_indent = <const char*>b' '

    for i in range(extract_nodes.size()):
        current_node = extract_nodes[i].get()

        if opts.preserve_formatting:
            if current_node.tag_id in [LXB_TAG_UL, LXB_TAG_OL] \
                    or (current_node.tag_id == LXB_TAG_LI and list_depth == 0):
                if current_node.is_end_tag:
                    predec(list_depth)
                    list_numbering.pop_back()
                    bullet_deferred = False
                else:
                    preinc(list_depth)
                    list_numbering.push_back(<size_t>(current_node.tag_id == LXB_TAG_OL))

            if current_node.tag_id == LXB_TAG_LI:
                bullet_deferred = True

        if current_node.tag_id != LXB_TAG_TEXTAREA:
            _make_margin(current_node, opts, bullet_deferred, output)

        if current_node.text_contents.get() == NULL:
            continue

        element_text = deref(current_node.text_contents)
        if not current_node.is_pre or current_node.is_end_tag:
            element_text = rstrip_str(element_text)

        if element_text.empty():
            continue

        if list_depth > 0:
            if current_node.is_pre and opts.preserve_formatting:
                element_text = _indent_newlines(element_text, list_depth + <size_t>opts.list_bullets)
            if opts.preserve_formatting:
                list_item_indent = string(2 * list_depth + 2 * <size_t>(
                        not bullet_deferred and opts.list_bullets), <char>b' ')
            if bullet_deferred:
                if opts.list_bullets and list_numbering.back() == 0:
                    list_item_indent += LIST_BULLET + <const char*>b' '
                elif opts.list_bullets:
                    list_item_indent += to_string(list_numbering.back()) + <const char*>b'. '
                    preinc(list_numbering.back())
                bullet_deferred = False
            element_text = list_item_indent + element_text

        if opts.preserve_formatting and current_node.tag_id in [LXB_TAG_TD, LXB_TAG_TH]:
            if not output.empty() and output.back() != b'\n':
                output.append(b'\t\t')

        output.append(element_text)
        # if current_node.tag_id == LXB_TAG_TEXTAREA:
        #     _make_margin(current_node, opts, bullet_deferred, output)

    return output


cdef bint _is_unprintable_pua(lxb_dom_node_t* node) nogil:
    """Whether text node contains only a single unprintable code point from the private use area."""
    if node.first_child and (node.first_child.next or node.first_child.type != LXB_DOM_NODE_TYPE_TEXT):
        # Node has more than one child
        return False
    if not node.first_child and node.type != LXB_DOM_NODE_TYPE_TEXT:
        return False

    cdef string element_text = strip_str(get_node_text(node))
    if element_text.size() > 3:
        return False

    # Pilcrow character (probably an anchor link)
    if element_text == b'\xc2\xb6':
        return True

    # BMP private use area (probably an icon font)
    cdef uint32_t cp = 0
    if element_text.size() == 3:
        memcpy(&cp, element_text.data(), 3 * sizeof(char))
        if 0x8080ee <= cp <= 0xbfa3ef:
            return True

    return False


cdef RE2Options re_opts
re_opts.set_case_sensitive(False)

cdef RE2 article_cls_regex = RE2(rb'(?:^|[\s_-])(?:article|entry|post|story|single[_-]?post|main)(?:content|body|text|page)?(?:$|[\s_-])', re_opts)
cdef RE2 nav_cls_regex = RE2(rb'(?:^|\s)(?:[a-z]-)?(?:(?:main|site|page|sub|article)[_-]*)?(?:nav(?:bar|igation|box)?|menu(?:[_-]item)?|dropdown|bread[_-]?crumbs?)|(?:link[_-]?(?:list|container))(?:$|[\s_-])', re_opts)
cdef RE2 recommended_cls_regex = RE2(rb'(?:^|[\s_-])(?:trends|trending|recommended|popular|editorial|editors?[_-]picks|(?:related|more)[_-]?(?:links|articles|posts|guides|stories))(?:$|[\s_-])', re_opts)
cdef RE2 header_cls_regex = RE2(rb'(?:^|\s)(?:[a-z]-)?(?:global|page|site|full)[_-]*header|header[_-](?:wrap(?:per)?|bar)(?:$|\s)', re_opts)
cdef RE2 footer_cls_regex = RE2(rb'(?:^|[\s_-])(?:global|page|site|copyright)?(?:footer|copyright|cookie|consent|legal)(?:$|[\s_-])', re_opts)
cdef RE2 post_meta_cls_regex = RE2(rb'(?:^|[\s_-])(?:(?:post|entry|article(?:page)?|content|story|section)[_-]*(?:text[_-]*)?(?:footer|teaser|meta|subline|sidebar|author(?:name)?|published|timestamp|date|posted[_-]?on|info|labels?|tags?|keywords|category)|byline|author-date)(?:$|[\s_-])', re_opts)
cdef RE2 sidebar_cls_regex = RE2(rb'(?:^|\s)(?:[a-z]-)?(?:right|left|global)?sidebar(?:$|[\s_-])', re_opts)
cdef RE2 search_cls_regex = RE2(rb'(?:^|[\s_-])search(?:[_-]?(?:bar|facility|box))?(?:$|\s)', re_opts)
cdef RE2 skip_link_cls_regex = RE2(rb'(?:^|\s)(?:skip(?:[_-]?(?:to|link))|scroll[_-]?(?:up|down)|next|prev(?:ious)?|permalink|pagination)(?:$|\s|[_-]?(?:post|article))', re_opts)
cdef RE2 display_cls_regex = RE2(rb'(?:^|\s)(?:is[_-])?(?:display-none|hidden|invisible|collapsed|h-0|nocontent|expandable)(?:-xs|-sm|-lg|-2?xl)?(?:$|\s)', re_opts)
cdef RE2 display_css_regex = RE2(rb'(?:^|;\s*)(?:display\s?:\s?none|visibility\s?:\s?hidden)(?:$|\s?;)', re_opts)
cdef RE2 modal_cls_regex = RE2(rb'(?:^|\s)(?:modal|popup|lightbox|gallery)(?:[_-]*(?:window|pane|box))?(?:$|[\s_-])', re_opts)
cdef RE2 signin_cls_regex = RE2(rb'(?:^|\s)(?:(?:log[_-]?in|sign[_-]?(?:in|up)|account)|user[_-](?:info|profile|settings))(?:$|[\s_-])', re_opts)
cdef RE2 ads_cls_regex = RE2(rb'(?:^|\s)(?:)?(?:(?:google|wide)[_-]?ad|ad(?:vert|vertise(?:|ment|link)|$|_[a-f0-9]+)|sponsor(?:ed)?|promoted|paid|(?:wide)?banner|donate)(?:$|[\s_-])', re_opts)
cdef RE2 social_cls_regex = RE2(rb'(?:^|\s|__|--)(?:[a-z]-)?(?:social(?:media|search)?|share(?:daddy)?|syndication|newsletter|sharing|likes?|(?:give[_-]?)?feedback|(?:brand[_-])?engagement|facebook|twitter|subscribe|wabtn|jp-)(?:[_-]?(?:post|links?|section|icons?))?(?:$|[\s_-])', re_opts)
cdef RE2 comments_cls_regex = RE2(rb'(?:^|[\s_-])(?:(?:article|user|post)[_-]*)?(?:(?:no[_-]?)?comments?|comment[_-]?list|reply)(?:$|[\s_-])', re_opts)
cdef RE2 logo_cls_regex = RE2(rb'(?:^|[\s_-])(?:brand[_-]*)?logo(?:$|\s)', re_opts)


cdef inline bint regex_search_not_empty(const StringPiece& s, const RE2& r) nogil:
    if s.empty():
        return False
    return PartialMatch(s, r())


cdef bint _is_main_content_node(lxb_dom_node_t* node, bint allow_comments) nogil:
    """Check with simple heuristics if node belongs to main content."""

    if node.type != LXB_DOM_NODE_TYPE_ELEMENT:
        return True

    if node.local_name == LXB_TAG_BODY:
        return True

    cdef bint is_block = is_block_element(node.local_name)


    # ------ Section 1: Inline and block elements ------

    if not is_block and _is_unprintable_pua(node):
        return False

    # Hidden elements
    if lxb_dom_element_has_attribute(<lxb_dom_element_t*>node, <lxb_char_t*>b'hidden', 6):
        return False

    # rel attributes
    cdef string_view rel_attr = get_node_attr_sv(node, b'rel')
    if not rel_attr.empty() and rel_attr in [b'bookmark', b'author', b'icon', b'search', b'prev', b'next']:
        return False

    # itemprop attributes
    cdef string_view itemprop_attr = get_node_attr_sv(node, b'itemprop')
    if not itemprop_attr.empty() and itemprop_attr in [b'datePublished', b'author', b'url']:
        return False

    # ARIA hidden
    if get_node_attr_sv(node, b'aria-hidden') == b'true':
        return False

    # ARIA expanded
    if get_node_attr_sv(node, b'aria-expanded') == b'false':
        return False

    # ARIA roles
    cdef string_view role_attr = get_node_attr_sv(node, b'role')
    if not role_attr.empty() and role_attr in [b'contentinfo', b'img', b'menu', b'menubar', b'navigation', b'menuitem',
                                               b'alert', b'dialog', b'checkbox', b'radio', b'complementary']:
        return False

    # Block element matching based only on tag name
    cdef size_t length_to_body = 0
    cdef lxb_dom_node_t* pnode = node
    cdef bint footer_is_last_body_child = True

    if is_block or node.local_name == LXB_TAG_A:
        while pnode.local_name != LXB_TAG_BODY and pnode.parent:
            preinc(length_to_body)
            pnode = pnode.parent

    if is_block:
        # Main elements
        if node.local_name == LXB_TAG_MAIN:
            return True

        # Global footer
        if node.local_name == LXB_TAG_FOOTER:
            if length_to_body < 3:
                return False

            # Check if footer is recursive last element node of a direct body child
            pnode = node
            while pnode and pnode.parent and pnode.parent.local_name != LXB_TAG_BODY:
                if pnode.next and pnode.next.type == LXB_DOM_NODE_TYPE_TEXT:
                    pnode = pnode.next
                if pnode.next:
                    # There is at least one more element node
                    footer_is_last_body_child = False
                    break
                pnode = pnode.parent
            if footer_is_last_body_child:
                return False

        # Global navigation
        if node.local_name in [LXB_TAG_UL, LXB_TAG_NAV] and length_to_body < 8:
            return False

        # Global aside
        if node.local_name == LXB_TAG_ASIDE and length_to_body < 8:
            return False

        # Iframes
        if node.local_name == LXB_TAG_IFRAME:
            return False


    # ------ Section 2: General class and id matching ------

    cdef StringPiece cls_attr = get_node_attr_sp(node, b'class')
    cdef StringPiece id_attr = get_node_attr_sp(node, b'id')
    if cls_attr.empty() and id_attr.empty():
        return True

    cdef string cls_and_id_attr_str = cls_attr.as_string()
    if not cls_and_id_attr_str.empty():
        cls_and_id_attr_str.push_back(b' ')
    cls_and_id_attr_str.append(id_attr.as_string())
    cdef StringPiece cls_and_id_attr = StringPiece(cls_and_id_attr_str)

    # Hidden elements
    if regex_search_not_empty(cls_attr, display_cls_regex) \
            or regex_search_not_empty(get_node_attr_sp(node, b'style'), display_css_regex):
        return False

    # Skip links
    if node.local_name in [LXB_TAG_A, LXB_TAG_DIV, LXB_TAG_LI] and \
            regex_search_not_empty(cls_and_id_attr, skip_link_cls_regex):
        return False

    if length_to_body > 2:
        # Sign-in links
        if regex_search_not_empty(cls_attr, signin_cls_regex):
            return False

        # Post meta
        if regex_search_not_empty(cls_attr, post_meta_cls_regex):
            return False

        # Social media and feedback forms
        if regex_search_not_empty(cls_attr, social_cls_regex):
            return False

    # Logos
    if regex_search_not_empty(cls_and_id_attr, logo_cls_regex):
        return False

    # Ads
    if regex_search_not_empty(cls_and_id_attr, ads_cls_regex) \
            or lxb_dom_element_has_attribute(<lxb_dom_element_t*>node, <lxb_char_t*>b'data-ad', 7) \
            or lxb_dom_element_has_attribute(<lxb_dom_element_t*>node, <lxb_char_t*>b'data-advertisement', 18) \
            or lxb_dom_element_has_attribute(<lxb_dom_element_t*>node, <lxb_char_t*>b'data-text-ad', 12):
        return False


    # ------ Section 3: Class and id matching of block elements only ------

    if not is_block:
        return True

    # Whitelist article elements
    if regex_search_not_empty(cls_and_id_attr, article_cls_regex):
        return True

    # Global header
    if regex_search_not_empty(cls_and_id_attr, header_cls_regex):
        return False

    # Global footer
    if regex_search_not_empty(cls_and_id_attr, footer_cls_regex):
        return False

    # Global navigation
    if regex_search_not_empty(cls_and_id_attr, nav_cls_regex):
        return False

    # Recommended articles
    if regex_search_not_empty(cls_and_id_attr, recommended_cls_regex):
        return False

    # Comments section
    if not allow_comments and node.local_name and regex_search_not_empty(cls_and_id_attr, comments_cls_regex):
        return False

    # Global search bar
    if regex_search_not_empty(cls_and_id_attr, search_cls_regex):
        return False

    # Global sidebar
    if regex_search_not_empty(cls_and_id_attr, sidebar_cls_regex):
        return False

    # Modals
    if regex_search_not_empty(cls_and_id_attr, modal_cls_regex):
        return False

    return True


cdef inline lxb_status_t _collect_selected_nodes_cb(lxb_dom_node_t *node,
                                                    lxb_css_selector_specificity_t *spec, void *ctx) nogil:
    (<stl_set[lxb_dom_node_t*]*>ctx).insert(node)
    return LXB_STATUS_OK


def extract_plain_text(DOMNode base_node, bint preserve_formatting=True, bint main_content=False,
                       bint list_bullets=True,  bint alt_texts=True, bint links=False, bint form_fields=False,
                       bint noscript=False, bint comments=True, skip_elements=None):
    """
    extract_plain_text(base_node, preserve_formatting=True, preserve_formatting=True, main_content=False, \
        list_bullets=True, alt_texts=False, links=True, form_fields=False, noscript=False, skip_elements=None)

    Perform a simple plain-text extraction from the given DOM node and its children.

    Extracts all visible text (excluding script/style elements, comment nodes etc.)
    and collapses consecutive white space characters. If ``preserve_formatting`` is
    ``True``, line breaks, paragraphs, other block-level elements, list elements, and
    ``<pre>``-formatted text will be preserved.

    Extraction of particular elements and attributes such as links, alt texts, or form fields
    can be be configured individually by setting the corresponding parameter to ``True``.
    Defaults to ``False`` for most elements (i.e., only basic text will be extracted).

    :param base_node: base DOM node of which to extract sub tree
    :type base_node: DOMNode
    :param preserve_formatting: preserve basic block-level formatting
    :type preserve_formatting: bool
    :param main_content: apply simple heuristics for extracting only "main-content" elements
    :type main_content: bool
    :param list_bullets: insert bullets / numbers for list items
    :type list_bullets: bool
    :param alt_texts: preserve alternative text descriptions
    :type alt_texts: bool
    :param links: extract link target URLs
    :type links: bool
    :param form_fields: extract form fields and their values
    :type form_fields: bool
    :param noscript: extract contents of <noscript> elements
    :param comments: treat comment sections as main content
    :type comments: bool
    :param skip_elements: list of CSS selectors for elements to skip (defaults to ``head``, ``script``, ``style``)
    :type skip_elements: t.Iterable[str] or None
    :type noscript: bool
    :return: extracted plain text
    :rtype: str
    """
    if not check_node(base_node):
        return ''

    skip_selectors = {e.encode() for e in skip_elements or []}
    skip_selectors.update({b'script', b'style'})
    if not alt_texts:
        skip_selectors.update({b'object', b'video', b'audio', b'embed' b'img', b'area',
                               b'svg', b'figcaption', b'figure'})
    if not noscript:
        skip_selectors.add(b'noscript')
    if not form_fields:
        skip_selectors.update({b'textarea', b'input', b'button', b'select', b'option', b'label',})

    cdef ExtractContext ctx
    ctx.root_node = base_node.node
    ctx.node = base_node.node
    ctx.opts = [
        preserve_formatting,
        list_bullets,
        links,
        alt_texts,
        form_fields,
        noscript]

    cdef const lxb_char_t* tag_name = NULL
    cdef size_t tag_name_len
    cdef string tag_name_str
    cdef size_t i
    cdef bint skip = False
    cdef bint is_end_tag = False

    if ctx.node.type == LXB_DOM_NODE_TYPE_DOCUMENT:
        ctx.root_node = next_element_node(ctx.node, ctx.node.first_child)
        ctx.node = ctx.root_node

    cdef lxb_css_parser_t* css_parser = NULL
    cdef lxb_css_selectors_t* css_selectors = NULL
    cdef lxb_selectors_t* selectors = NULL

    cdef lxb_css_selector_list_t* selector_list = NULL
    cdef stl_set[lxb_dom_node_t*] preselected_nodes
    cdef string main_content_selector = b'.article-body, .articleBody, .contentBody, .article-text, .main-content,' \
                                        b'.postcontent, .post-content, .single-post, [role="main"]'
    try:
        init_css_parser(&css_parser)
        init_css_selectors(css_parser, &css_selectors, &selectors)

        # Opportunistically try to find general main content zone
        selector_list = parse_css_selectors(css_parser, <lxb_char_t*>main_content_selector.data(),
                                            main_content_selector.size())
        lxb_selectors_find(selectors, ctx.root_node, selector_list,
                           <lxb_selectors_cb_f>_collect_selected_nodes_cb, &preselected_nodes)
        if preselected_nodes.size() == 1:
            # Use result only if there is exactly one match
            ctx.root_node = deref(preselected_nodes.begin())
            ctx.node = ctx.root_node

        # Select all blacklisted elements and save them in an ordered set
        preselected_nodes.clear()
        combined_skip_sel = b','.join(skip_selectors)
        selector_list = parse_css_selectors(css_parser, <lxb_char_t*>combined_skip_sel, len(combined_skip_sel))
        lxb_selectors_find(selectors, ctx.root_node, selector_list,
                           <lxb_selectors_cb_f>_collect_selected_nodes_cb, &preselected_nodes)
    finally:
        destroy_css_selectors(css_selectors, selectors)
        destroy_css_parser(css_parser)

    cdef vector[shared_ptr[ExtractNode]] extract_nodes
    extract_nodes.reserve(150)
    with nogil:
        while ctx.node:
            # Skip everything except element and text nodes
            if ctx.node.type != LXB_DOM_NODE_TYPE_ELEMENT and ctx.node.type != LXB_DOM_NODE_TYPE_TEXT:
                is_end_tag = True
                ctx.node = next_node(ctx.root_node, ctx.node, &ctx.depth, &is_end_tag)
                continue

            if ctx.node.local_name == LXB_TAG_HEAD:
                is_end_tag = True
                ctx.node = next_node(ctx.root_node, ctx.node, &ctx.depth, &is_end_tag)
                continue

            # Skip blacklisted or non-main-content nodes
            if preselected_nodes.find(ctx.node) != preselected_nodes.end() or \
                    (main_content and not _is_main_content_node(ctx.node, comments)):
                is_end_tag = True
                ctx.node = next_node(ctx.root_node, ctx.node, &ctx.depth, &is_end_tag)
                continue

            _extract_cb(extract_nodes, ctx, is_end_tag)

            ctx.node = next_node(ctx.root_node, ctx.node, &ctx.depth, &is_end_tag)

    return bytes_to_str(_serialize_extract_nodes(extract_nodes, ctx.opts)).rstrip()
