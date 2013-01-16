# Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

import logging
import re
import json
from webapp2 import *
from datetime import datetime, timedelta
from google.appengine.ext import blobstore
from google.appengine.ext.webapp import blobstore_handlers
from google.appengine.api import files, memcache

LATEST_CONTINUOUS_VERSION_FILE = '/gs/dart-editor-archive-continuous/latest/VERSION'
LATEST_RELEASE_VERSION_FILE = '/gs/dart-editor-archive-integration/latest/VERSION'
LATEST_TRUNK_VERSION_FILE = '/gs/dart-editor-archive-trunk/latest/VERSION'
ONE_HOUR = 60 * 60
ONE_DAY = ONE_HOUR * 24
ONE_WEEK = ONE_DAY * 7

class ApiDocs(blobstore_handlers.BlobstoreDownloadHandler):

  latest_doc_version = None
  latest_release_doc_version = None
  latest_trunk_doc_version = None
  next_doc_version_check = None

  def reload_latest_version(self, version_file_location):
    data = None
    with files.open(version_file_location, 'r') as f:
      data = json.loads(f.read(1024))
      ApiDocs.next_doc_version_check = datetime.now() + timedelta(days=1)
    return int(data['revision'])

  # TODO: put into memcache?
  def get_latest_version(self, version, version_file_location):
    forced_reload = self.request.get('force_reload')
    if (forced_reload or
          version is None or
          ApiDocs.next_doc_version_check is None or
          datetime.now() > ApiDocs.next_doc_version_check):
      new_version = self.reload_latest_version(version_file_location)
      return new_version
    else:
      return version

  def get_cache_age(self, path):
    if re.search(r'(png|jpg)$', path):
      age = ONE_DAY
    elif path.endswith('.ico'):
      age = ONE_WEEK
    else:
      age = ONE_HOUR
    return age

  def build_path(self, prefix, version_num):
    return self.request.path.replace(prefix,
          '/gs/dartlang-api-docs/' + str(version_num))

  def resolve_doc_path(self):
    if self.request.path.startswith('/docs/bleeding_edge'):
      version_num = self.get_latest_version(ApiDocs.latest_doc_version, LATEST_CONTINUOUS_VERSION_FILE)
      ApiDocs.latest_doc_version = version_num
      path = self.build_path('/docs/bleeding_edge', version_num)
    elif self.request.path.startswith('/docs/releases/latest'):
      version_num = self.get_latest_version(ApiDocs.latest_release_doc_version, LATEST_RELEASE_VERSION_FILE)
      ApiDocs.latest_release_doc_version = version_num
      path = self.build_path('/docs/releases/latest', version_num)
    elif self.request.path.startswith('/docs/trunk/latest'):
      version_num = self.get_latest_version(ApiDocs.latest_trunk_doc_version, LATEST_TRUNK_VERSION_FILE)
      ApiDocs.latest_trunk_doc_version = version_num
      path = self.build_path('/docs/trunk/latest', version_num)

    if path.endswith('/'):
      path = path + 'index.html'
    return path

  def get(self):
    path = self.resolve_doc_path()
    gs_key = blobstore.create_gs_key(path)
    age = self.get_cache_age(path)

    self.response.headers['Cache-Control'] = 'max-age=' + \
        str(age) + ',s-maxage=' + str(age)

    # is there a better way to check if a file exists in cloud storage?
    # AE will serve a 500 if the file doesn't exist, but that should
    # be a 404

    path_exists = memcache.get(path)
    if path_exists is not None:
      if path_exists == "1":
        self.send_blob(gs_key)
      else:
        self.error(404)
    else:
      try:
        # just check for existance
        files.open(path, 'r').close()
        memcache.add(key=path, value="1", time=ONE_DAY)
        self.send_blob(gs_key)
      except files.file.ExistenceError:
        memcache.add(key=path, value="0", time=ONE_DAY)
        self.error(404)

  # this doesn't get called, unfortunately.
  # if this ever starts working, remove the try and files.open
  # from get, above, and instead retroactively handle a missing file here
  # def handle_exception(self, exception, debug_mode):
  #   # awful hack for when file in cloud storage doesn't exist
  #   if isinstance(exception, TypeError):
  #     logging.debug('oh noes!')
  #     path = self.resolve_path()
  #     try:
  #       with files.open(path, 'r') as f:
  #         # the file really does exist, so 500 must be something else
  #         self.error(500)
  #     except files.file.ExistenceError:
  #       # file does not exist
  #       self.error(404)
  #   else:
  #     logging.exception(exception)

def redir_to_latest(handler, *args, **kwargs):
  path = kwargs['path']
  if re.search(r'^(core|coreimpl|crypto|io|isolate|json|uri|html|math|utf|web)', path):
    return '/docs/releases/latest/dart_' + path
  else:
    return '/docs/releases/latest/' + path

def redir_dom(handler, *args, **kwargs):
  return '/docs/bleeding_edge/dart_html' + kwargs['path']

def redir_continuous(handler, *args, **kwargs):
  return '/docs/bleeding_edge' + kwargs['path']

application = WSGIApplication(
  [
    Route('/dom<path:.*>', RedirectHandler, defaults={'_uri': redir_dom}),
    Route('/docs/continuous<path:.*>', RedirectHandler, defaults={'_uri': redir_continuous}),
    ('/docs.*', ApiDocs),
    Route('/<path:.*>', RedirectHandler, defaults={'_uri': redir_to_latest})
  ],
  debug=True)
