# api.dartlang.org server

An App Engine server that fronts a Google Cloud Storage
repository of Dart API docs. 

See LICENSE.

## Link structure

First, read how
[dartdoc structures links](https://github.com/dart-lang/dartdoc/blob/master/README.md#link-structure).

The api.dartlang.org prepends some structure to the links from dartdoc.

```
/             ==> /stable
/stable       ==> /<latest-stable-version>/index.html
/dev          ==> /latest-dev-version>/index.html
/be           ==> /<latest-bleeding-edge-version>/index.html

/stable/dart-async/Future-class.html ==> /<latest-stable-version>/dart-async/Future-class.html
(same for dev and be)
```

## Deployment 

1. Download the [Google App Engine SDK for Python][GAE] and add it to your 
PATH.

1. Run `appcfg.py update <folder containing app.yaml>`.

[GAE]: https://developers.google.com/appengine/downloads#Google_App_Engine_SDK_for_Python "Google App Engine SDK for Python"
