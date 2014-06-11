dart-api-app
============

An App Engine server that fronts a Google Cloud Storage
repository of Dart API docs. To be used in conjunction with the 
[dartdoc-viewer](https://github.com/dart-lang/dartdoc-viewer) checkout.

See LICENSE.

## Deployment 

(There are many steps here, but most are "check to make sure this is a certain
way". Also, nice deployment script coming in the future!)

### In your dartdoc-viewer checkout

1. Make sure in `client/lib/shared.dart` so 
that the `useHistory` boolean is `true`! App Engine will have a very hard time
resolving URLs if that is false!

1. Ensure you have a file at 
`lib/config/config.yaml`, which contains the key for Google Analytics for your 
website. Main Dart API site's file can be found here: 
[Link TBD](http://google.com).

1. While standing in the `client` directory, type `pub build` .

1. _If_ there is a docs folder inside `client/build`, delete it!

### In your api.dartlang.org checkout 

1. Copy the `client/build` directory from your dartdoc-viewer checkout to 
`server/out/web` in your api.dartlang.org checkout.

1. Download the [Google App Engine SDK for Python][GAE] and add it to your 
PATH.

1. Run `appcfg.py update <folder containing app.yaml>`.

[GAE]: https://developers.google.com/appengine/downloads#Google_App_Engine_SDK_for_Python "Google App Engine SDK for Python"
