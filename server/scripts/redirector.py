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

ONE_HOUR = 60 * 60
ONE_DAY = ONE_HOUR * 24
ONE_WEEK = ONE_DAY * 7

class ApiDocs(blobstore_handlers.BlobstoreDownloadHandler):
  version_files = {
    'be': '/gs/dart-archive/channels/be/raw/latest/VERSION',
    'dev': '/gs/dart-archive/channels/dev/release/latest/VERSION',
    'stable': '/gs/dart-archive/channels/stable/release/latest/VERSION',
  }

  version_file_update_intervalls = {
    'be': timedelta(minutes=30),
    'dev': timedelta(hours=6),
    'stable': timedelta(days=1),
  }

  next_version_checks = {
    'be': None,
    'dev': None,
    'stable': None,
  }

  latest_versions = {
    'be': None,
    'dev': None,
    'stable': None,
  }

  def reload_latest_version(self, channel):
    data = None
    version_file_location = ApiDocs.version_files[channel]
    update_interval = ApiDocs.version_file_update_intervalls[channel]
    with files.open(version_file_location, 'r') as f:
      data = json.loads(f.read(1024))
      ApiDocs.next_version_checks[channel] = datetime.now() + update_interval
    revision = int(data['revision'])
    ApiDocs.latest_versions[channel] = revision
    return revision

  # TODO: put into memcache?
  def get_latest_version(self, channel):
    forced_reload = self.request.get('force_reload')
    version = ApiDocs.latest_versions[channel]
    next_version_check = ApiDocs.next_version_checks[channel]
    if (forced_reload or
        version is None or
        next_version_check is None or
        datetime.now() > next_version_check):
      return self.reload_latest_version(channel)
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

  def build_gcs_path(self, version_num, postfix, channel):
    if version_num:
      return '/gs/dartlang-api-docs/channels/%s/%s%s' % (
          channel, version_num, postfix)
    else:
      return '/gs/dartlang-api-docs/channels/%s%s' % (channel, postfix)

  def resolve_doc_path(self):
    docs_renames = [
      {
        'prefix': '/docs/channels/be/latest',
        'channel': 'be',
      },
      {
        'prefix': '/docs/channels/be',
        'channel': 'be',
        'manual_revision': True,
      },
      {
        'prefix': '/docs/channels/dev/latest',
        'channel': 'dev',
      },
      {
        'prefix': '/docs/channels/dev',
        'channel': 'dev',
        'manual_revision': True,
      },
      {
        'prefix': '/docs/channels/stable/latest',
        'channel': 'stable',
      },
      {
        'prefix': '/docs/channels/stable',
        'channel': 'stable',
        'manual_revision': True,
      },
    ]

    path = None
    for rename in docs_renames:
      prefix = rename['prefix']
      if self.request.path.startswith(prefix):
        channel = rename['channel']
        manual_revision = rename.get('manual_revision', False)

        postfix = self.request.path[len(prefix):]

        # If the URL doesn't include '/latest', we assume it's starting with a
        # revision number, so we don't prepend the gcs path with the latest
        # revision.
        if manual_revision:
          version_num = None
        else:
          version_num = self.get_latest_version(channel)
        path = self.build_gcs_path(version_num, postfix, channel)
        break

    if path and path.endswith('/'):
      path = path + 'index.html'
    return path

  def get(self):
    gcs_path = self.resolve_doc_path()
    if not gcs_path:
      self.error(404)
      return

    gs_key = blobstore.create_gs_key(gcs_path)
    age = self.get_cache_age(gcs_path)

    self.response.headers['Cache-Control'] = 'max-age=' + \
        str(age) + ',s-maxage=' + str(age)

    # is there a better way to check if a file exists in cloud storage?
    # AE will serve a 500 if the file doesn't exist, but that should
    # be a 404

    path_exists = memcache.get(gcs_path)
    if path_exists is not None:
      if path_exists == "1":
        self.send_blob(gs_key)
      else:
        logging.debug('Memcache said ' + gcs_path + ' does not exist, sending 404')
        self.error(404)
    else:
      try:
        # just check for existance
        files.open(gcs_path, 'r').close()
        memcache.add(key=gcs_path, value="1", time=ONE_DAY)
        self.send_blob(gs_key)
      except files.file.ExistenceError:
        memcache.add(key=gcs_path, value="0", time=ONE_DAY)
        logging.debug('Could not open ' + gcs_path + ', sending 404')
        self.error(404)

  # this doesn't get called, unfortunately.
  # if this ever starts working, remove the try and files.open
  # from get, above, and instead retroactively handle a missing file here
  # def handle_exception(self, exception, debug_mode):
  #   # awful hack for when file in cloud storage doesn't exist
  #   if isinstance(exception, TypeError):
  #     logging.debug('oh noes!')
  #     gcs_path = self.resolve_doc_path()
  #     try:
  #       with files.open(gcs_path, 'r') as f:
  #         # the file really does exist, so 500 must be something else
  #         self.error(500)
  #     except files.file.ExistenceError:
  #       # file does not exist
  #       self.error(404)
  #   else:
  #     logging.exception(exception)

def redir_to_latest(handler, *args, **kwargs):
  path = kwargs['path']
  if re.search(r'^(async|collection|convert|core|html|indexed_db|io|isolate|js|math|mirrors|svg|typed_data|web_audio|web_gl|web_sql)', path):
    return '/docs/channels/stable/latest/dart_' + path
  else:
    return '/docs/channels/stable/latest/' + path

def redir_dom(handler, *args, **kwargs):
  return '/docs/channels/stable/latest/dart_html' + kwargs['path']

def redir_continuous(handler, *args, **kwargs):
  return '/docs/channels/be/latest' + kwargs['path']

def redir_latest(handler, *args, **kwargs):
  return '/docs/channels/stable/latest' + kwargs['path']

def redir_pkgs(handler, *args, **kwargs):
  return '/docs/channels/stable/latest/' + kwargs['pkg'] + '.html'

application = WSGIApplication(
  [
    Route('/docs/pkg/<pkg:args|crypto|custom_element|fixnum|http_server|intl|json|logging|matcher|mime|mock|observe|path|polymer|polymer_expressions|sequence_zip|serialization|source_maps|template_binding|unittest|unmodifiable_collection|utf><:/?>',
        RedirectHandler, defaults={'_uri': redir_pkgs, '_code': 302}),
    Route('/dom<path:.*>', RedirectHandler, defaults={'_uri': redir_dom}),
    Route('/docs/bleeding_edge<path:.*>', RedirectHandler, defaults={'_uri': redir_continuous}),
    Route('/docs/continuous<path:.*>', RedirectHandler, defaults={'_uri': redir_continuous}),
    Route('/docs/releases/latest<path:.*>', RedirectHandler, defaults={'_uri': redir_latest}),
    ('/docs.*', ApiDocs),
    Route('/<path:.*>', RedirectHandler, defaults={'_uri': redir_to_latest})
  ],
  debug=True)
