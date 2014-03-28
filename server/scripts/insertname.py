# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

import logging
import re
from webapp2 import *
from google.appengine.api import files, memcache
 
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
    ('.*', ApiDocs),
  ],
  debug=True)
