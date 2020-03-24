# api.dart.dev server

An App Engine server that fronts a Google Cloud Storage
repository of Dart API docs.

See LICENSE.

## Link structure

First, read how
[dartdoc structures links](https://github.com/dart-lang/dartdoc/blob/master/README.md#link-structure).

The api.dart.dev server prepends some structure to the links from dartdoc.

```
/             ==> /stable
/stable       ==> /<latest-stable-version>/index.html
/beta         ==> /latest-beta-version>/index.html
/dev          ==> /latest-dev-version>/index.html
/be           ==> /<latest-bleeding-edge-version>/index.html

/stable/dart-async/Future-class.html ==> /<latest-stable-version>/dart-async/Future-class.html
(same for beta, dev, and be)
```

## Deployment

1. Install the [Google Cloud SDK][gcloud].

1. Run `gcloud auth login`

1. Run `gcloud config set app/promote_by_default false` to avoid accidentally
   deploying a test version.

1. Run `gcloud config set project dartlang-api`

1. Run `gcloud app deploy -v name-of-new-version server/app.yaml` and test

1. Run `gcloud app deploy -v name-of-new-version --promote server/app.yaml` to
   make this version the default


[gcloud]: https://cloud.google.com/sdk/downloads
