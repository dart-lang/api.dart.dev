import 'dart:html';
import 'package:web_ui/web_ui.dart';

const OPEN_CSS_CLASS = "open-details";

class Details extends WebComponent {
  bool _open = false;

  bool get open => _open == true;

  Element get summaryOnly => this.query(".summary-only");
  Element get expandedDetails => this.query(".expanded-details");

  void set open(bool value) {
    // Don't animate if this element wasn't previously initialized.
    if (value != open) {
      _open = value;

      // TODO(jacobr): use the Widget Dart animation framework instead
      // once it provides the required effect. At the moment, using the
      // animation framework results in janky UI.
      //  Swapper.swap(expandedDetails.parent, value ? expandedDetails : summaryOnly,
      //      effect: new ShrinkEffect(),
      //      duration: 280);

      num startHeight;
      num endHeight;
      if (value) {
        startHeight = summaryOnly.scrollHeight;
        endHeight = expandedDetails.scrollHeight;
      } else {
        startHeight = expandedDetails.scrollHeight;
        endHeight = summaryOnly.scrollHeight;
      }

      if (value) {
        classes.add(OPEN_CSS_CLASS);
      } else {
        classes.remove(OPEN_CSS_CLASS);
      }

      if (startHeight != endHeight) {
        expandedDetails.style.height = "${startHeight}px";
        summaryOnly.style.height = '0px';
        window.requestAnimationFrame((_) {
          expandedDetails.style.transition = "height .28s";
          window.requestAnimationFrame((_) {
            expandedDetails.style.height = "${endHeight}px";
            // TODO(jacobr): switch to auto. after transition completes.
            var subscription;
            subscription = expandedDetails.onTransitionEnd.listen((_){
              expandedDetails.style.transition = '';
              summaryOnly.style.removeProperty('height');
              expandedDetails.style.removeProperty('height');
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

