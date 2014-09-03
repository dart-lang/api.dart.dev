# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

import logging
import re
from webapp2 import *
from google.appengine.api import files, memcache
from redirector import redir_pkgs

# When we get a request for dart: libraries, before serving the static HTML,
# rewrite it to include
# a reference to the dynamic contents, changing the title and adding a mention
# at the bottom of the page. If we don't do this, search engine indexers
# treat all of our pages as duplicates and throw them away.
# 
# If the request is for a package, redirect it to dartdocs.org instead.
class ApiDocs(RequestHandler):

  def get(self, *args, **kwargs):
    prefix = 'dartdoc-viewer/'
    title = '<title>Dart API Reference</title>'
    nameMarker = '<p class="nameMarker">Dart API Documentation</p>'
    indexFilePath = os.path.join(os.path.dirname(__file__), '../index.html')
    indexFile = open(indexFilePath, 'r').read()
    path = self.request.path
    myPath = path[path.index(prefix) + len(prefix):]
    substituted = indexFile.replace(title, '<title>%s API Docs</title>' % myPath)
    substituted = substituted.replace(nameMarker,
      '<p class="nameMarker">Dart API Documentation for ' + myPath + '</p>\n')
    self.response.out.write(substituted)

application = WSGIApplication(
  [
    # Home and dart: libraries get handled normally.
    (r'/apidocs/channels/<:(stable)|(be)|(dev)>/dartdoc-viewer/dart<:.*>',
        ApiDocs),
    (r'/apidocs/channels/<:(stable)|(be)|(dev)>/dartdoc-viewer/home', ApiDocs),
    (r'/apidocs/channels/<:(stable)|(be)|(dev)>/dartdoc-viewer/home/', ApiDocs),

    # Everything else is a package and gets redirected to dartdocs.org.
    # TODO(alanknight): Once dartdocs supports URLS of the form latest/<stuff>
    # include "stuff", so we can redirect somewhere inside the latest of a
    # package, not just to its top level.
    Route(
        r'/apidocs/channels/<:(stable)|(be)|(dev)>'
            r'/dartdoc-viewer/<pkg:\w*><stuff:.*>',
        RedirectHandler,
        defaults={'_uri': redir_pkgs, '_code': 302 }),

    ('.*', ApiDocs),
  ],
  debug=True)
