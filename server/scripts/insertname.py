# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

import logging
import re
from webapp2 import *
from google.appengine.api import memcache
from redirector import redir_pkgs
import cloudstorage

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
    path = self.request.path
    myPath = path[path.index(prefix) + len(prefix):]
    if not myPath.startswith("dart"):
      # TODO(alanknight): Once dartdocs.org supports something after /latest
      # make use of the rest of the URL to go to the right place in the package.
      packageName = myPath.split("/")[0]
      self.redirect(redir_pkgs(self, pkg = packageName))
    else:
      indexFilePath = os.path.join(os.path.dirname(__file__), '../index.html')
      indexFile = open(indexFilePath, 'r').read()
      substituted = indexFile.replace(title, 
        '<title>%s API Docs</title>' % myPath)
      substituted = substituted.replace(nameMarker,
        '<p class="nameMarker">Dart API Documentation for ' + myPath + '</p>\n')
      self.response.out.write(substituted)

application = WSGIApplication(
  [
    ('.*', ApiDocs),
  ],
  debug=True)
