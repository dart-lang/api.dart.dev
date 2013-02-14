// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:html';
import 'package:web_ui/web_ui.dart';

const OPEN_CSS_CLASS = "open-details";

/**
 * Details [WebComponent] that toggles between displaying a summary and
 * expanded view in response to user clicks or model state changes.
 */
class Details extends WebComponent {

  bool _open = false;

  /** True whent the details component is open. */
  bool get open => _open == true;

  Element get _summaryOnly => _root.query(".summary-only");
  Element get _expandedDetails => _root.query(".expanded-details");

  void set open(bool value) {
    // Don't animate if this element wasn't previously initialized.
    if (value != open) {
      _open = value;

      // TODO(jacobr): use the Widget Dart animation framework instead
      // once it provides the required effect. At the moment, using the
      // animation framework results in janky UI.
      //  Swapper.swap(expandedDetails.parent,
      //      value ? expandedDetails : summaryOnly,
      //      effect: new ShrinkEffect(),
      //      duration: 280);

      num startHeight;
      num endHeight;
      if (value) {
        startHeight = _summaryOnly.scrollHeight;
        endHeight = _expandedDetails.scrollHeight;
      } else {
        startHeight = _expandedDetails.scrollHeight;
        endHeight = _summaryOnly.scrollHeight;
      }

      if (value) {
        classes.add(OPEN_CSS_CLASS);
      } else {
        classes.remove(OPEN_CSS_CLASS);
      }

      if (startHeight != endHeight) {
        _expandedDetails.style.height = "${startHeight}px";
        _summaryOnly.style.height = '0px';
        window.requestAnimationFrame((_) {
          _expandedDetails.style.transition = "height .28s";
          window.requestAnimationFrame((_) {
            _expandedDetails.style.height = "${endHeight}px";
            // TODO(jacobr): switch to auto. after transition completes.
            var subscription;
            subscription = _expandedDetails.onTransitionEnd.listen((_){
              _expandedDetails.style.transition = '';
              _summaryOnly.style.removeProperty('height');
              _expandedDetails.style.removeProperty('height');
              subscription.cancel();
            });
          });
        });
      }
    }
  }

  handleClick(Event e) {
    open = !open;
  }
}

