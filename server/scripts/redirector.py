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


class VersionInfo(object):
  """Small helper class holding information about the last version seen and the
  last time the version was checked for."""
  def __init__(self, update_interval):
    # The most recent version for this channel.
    self.version = None
    # The time this version was found.
    self.last_check = None
    self.update_interval = update_interval

  def should_update(self):
    """Tests to see if the last check was long enough past the update interval
    that we should update the version."""
    return datetime.now() > self.last_check + self.update_interval

class ApiDocs(blobstore_handlers.BlobstoreDownloadHandler):
  GOOGLE_STORAGE = '/gs/dartlang-api-docs/channels'
  PRETTY_VERSION_LOCATION = (
      '/gs/dart-archive/channels/%(channel)s/raw/%(rev)s/VERSION')

  def version_file_loc(self, channel):
    return '%s/%s/latest.txt' % (ApiDocs.GOOGLE_STORAGE, channel)

  # String to indicate we're looking for a specific version number/name.
  VERSION_DIRECTORY = '/buildversion/'

  # Dictionary of versions holding version information of the latest recorded
  # version number and the time when it was recorded.
  latest_versions = {
    'be': VersionInfo(timedelta(minutes=30)),
    'dev': VersionInfo(timedelta(hours=6)),
    'stable': VersionInfo(timedelta(days=1)),
  }

  def recheck_latest_version(self, channel):
    """Check Google storage to determine the latest version file in a given
    channel."""
    data = None
    version_file_location = self.version_file_loc(channel)
    with files.open(version_file_location, 'r') as f:
      data = json.loads(f.read(1024))
      ApiDocs.latest_versions[channel].last_check = datetime.now()
    revision = int(data)
    ApiDocs.latest_versions[channel].version = revision
    return revision

  def get_latest_version(self, channel):
    """Determine what the latest version number is for this particular channel.
    We do a bit of caching so that we're not constantly pinging for the latest
    version of stable, for example."""
    version_info = ApiDocs.latest_versions[channel]
    if (version_info.version is None or version_info.should_update()):
      return self.recheck_latest_version(channel)
    else:
      return version_info.version

  def get_pretty_latest_version(self, channel):
    """Look in an alternate storage location to get the "human readable" version
    of the SDK (e.g. 1.5). We don't look at this one initially to reduce the
    chance of data races, since the files are not uploaded to all repositories
    simultaneously."""
    data = None
    version_file_location = ApiDocs.PRETTY_VERSION_LOCATION % {
        'rev': self.get_latest_version(channel), 'channel': channel}
    with files.open(version_file_location, 'r') as f:
      data = json.loads(f.read(1024))
    version = data['version']
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
    """Build the path to the information on Google Storage."""
    return '%s/%s/%s/docgen%s' % (ApiDocs.GOOGLE_STORAGE, channel, version_num,
        postfix)

  def resolve_doc_path(self, channel):
    """Given the request URL, determine what specific docs version we should
    actually display."""
    path = None
    if channel:
      prefix = '/apidocs/channels/%s/docs' % channel
      postfix = self.request.path[len(prefix):]
      if postfix.startswith(ApiDocs.VERSION_DIRECTORY):
        postfix = postfix[len(ApiDocs.VERSION_DIRECTORY):]
        index = postfix.find('/')
        version_num = postfix[:index]
        postfix = postfix[index:]
      else:
        version_num = self.get_latest_version(channel)
      path = self.build_gcs_path(version_num, postfix, channel)

    if path and path.endswith('/'):
      path = path + 'index.html'
    return path

  def get_channel(self):
    """Quick accessor to examine a request and determine what channel
    (dev/stable/etc) we're looking at. Return None if we have a weird unexpected
    URL."""
    for channel in ApiDocs.latest_versions.keys():
      if self.request.path.startswith('/apidocs/channels/%s' % channel):
        return channel

  def get(self, *args, **kwargs):
    """The main entry point for handling the URL for those with ApiDocs as the
    handler. See http://webapp-improved.appspot.com/api/webapp2.html?highlight=
    redirecthandler#webapp2.RedirectHandler.get.

    Arguments:
    - args: Positional arguments passed to this URL handler
    - kwargs: Dictionary arguments passed to the hander; expecting at least one
      item in the dictionary with a key of 'path', which was populated from the
      regular expression matching in Route."""
    channel = self.get_channel()
    if (channel and self.request.path[len('/apidocs/channels/%s/docs' %
        channel):] == '/latest.txt'):
      self.response.text = unicode(self.get_pretty_latest_version(channel))
    else:
      gcs_path = self.resolve_doc_path(channel)
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
          logging.debug('Memcache said ' + gcs_path +
              ' does not exist, sending 404')
          self.error(404)
      else:
        try:
          # just check for existence
          files.open(gcs_path, 'r').close()
          memcache.add(key=gcs_path, value="1", time=ONE_DAY)
          self.send_blob(gs_key)
        except files.file.ExistenceError:
          memcache.add(key=gcs_path, value="0", time=ONE_DAY)
          logging.debug('Could not open ' + gcs_path + ', sending 404')
          self.error(404)

def redir_to_latest(handler, *args, **kwargs):
  path = kwargs['path']
  return '/apidocs/channels/stable/dartdoc-viewer/home'

def redir_dom(handler, *args, **kwargs):
  return '/docs/channels/stable/latest/dart_html' + kwargs['path']

def redir_continuous(handler, *args, **kwargs):
  return '/docs/channels/be/latest' + kwargs['path']

def redir_docgen_be(handler, *args, **kwargs):
  return '/docs/channels/be/latest/docgen' + kwargs['path']

def redir_docgen_dev(handler, *args, **kwargs):
  return '/docs/channels/dev/latest/docgen' + kwargs['path']

def redir_latest(handler, *args, **kwargs):
  return '/docs/channels/stable/latest' + kwargs['path']

def redir_docgen_stable(handler, *args, **kwargs):
  return '/docs/channels/stable/latest/docgen' + kwargs['path']

def redir_pkgs(handler, *args, **kwargs):
  return 'http://www.dartdocs.org/documentation/' + kwargs['pkg'] + '/latest'

# Redirect old apidoc URIs
def redir_old(kwargs, channel):
  """Crufty old code that hasn't been touched in a long time. Still here for
  legacy reasons to not break old links. :-/ Let sleeping dogs lie?"""
  old_path = kwargs['path'][1:]
  if (old_path == ''):
    return '/apidocs/channels/stable/dartdoc-viewer/home'
  split = old_path.split('/')
  firstPart = split[0]
  if (len(split) > 1):
    secondPart = '.' + split[1]
  else:
    secondPart = ''
  packages = ['args', 'crypto', 'custom_element', 'fixnum', 'http_server',
    'intl', 'json', 'logging', 'matcher', 'mime', 'mock', 'observe', 'path',
    'polymer', 'polymer_expressions', 'sequence_zip', 'serialization',
    'source_maps', 'template_binding', 'unittest', 'unmodifiable_collection',
    'utf']
  withNoDot = firstPart.split('.')[0]
  if withNoDot in packages:
    prefix = firstPart + '/' + firstPart
  else:
    prefix = firstPart.replace('_', ':', 1).replace('.html', '')
    # For old URLs like core/String.html. We know it's not a package, so
    # it ought to start with a dart: library
    if (not prefix.startswith("dart:")):
      prefix = "dart:" + prefix
  new_path = prefix + secondPart.replace('.html','')
  # Should be #! if we use that scheme
  return '/apidocs/channels/' + channel + '/dartdoc-viewer/' + new_path

def redir_old_be(handler, *args, **kwargs):
  return redir_old(kwargs, 'be')

def redir_old_dev(handler, *args, **kwargs):
  return redir_old(kwargs, 'dev')

def redir_old_stable(handler, *args, **kwargs):
  return redir_old(kwargs, 'stable')

application = WSGIApplication(
  [
    # Legacy URL redirection schemes.
    # Redirect all old URL package requests to our updated URL scheme.
    # TODO(efortuna): Remove this line when pkg gets moved off of
    # api.dartlang.org.
    Route('/docs/pkg/<pkg:args|crypto|custom_element|fixnum|http_server|intl|'
        'json|logging|matcher|mime|mock|observe|path|polymer|'
        'polymer_expressions|sequence_zip|serialization|source_maps|'
        'template_binding|unittest|unmodifiable_collection|utf><:/?>',
        RedirectHandler, defaults={'_uri': redir_pkgs, '_code': 302}),
    Route('/dom<path:.*>', RedirectHandler, defaults={'_uri': redir_dom}),
    Route('/docs/bleeding_edge<path:.*>', RedirectHandler,
        defaults={'_uri': redir_continuous}),

    # Data requests go to cloud storage
    Route('/apidocs/channels/be/docs<path:.*>', ApiDocs),
    Route('/apidocs/channels/dev/docs<path:.*>', ApiDocs),
    Route('/apidocs/channels/stable/docs<path:.*>', ApiDocs),

    # Add the trailing / if necessary.
    Route('/apidocs/channels/be/dartdoc-viewer', RedirectHandler,
        defaults={'_uri': '/apidocs/channels/be/dartdoc-viewer/'}),
    Route('/apidocs/channels/dev/dartdoc-viewer', RedirectHandler,
        defaults={'_uri': '/apidocs/channels/dev/dartoc-viewer/'}),
    Route('/apidocs/channels/stable/dartdoc-viewer', RedirectHandler,
        defaults={'_uri': '/apidocs/channels/stable/dartdoc-viewer/'}),

    Route('/docs/continuous<path:.*>', RedirectHandler,
        defaults={'_uri': redir_continuous}),
    Route('/docs/releases/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_latest}),

     # Legacy handling: redirect old doc links to apidoc.
    Route('/docs/channels/be/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_old_be}),
    Route('/docs/channels/dev/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_old_dev}),
    Route('/docs/channels/stable/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_old_stable}),
    Route('/docs/channels/be', RedirectHandler,
        defaults={'_uri': '/apidocs/channels/be/'}),
    Route('/docs/channels/dev', RedirectHandler,
        defaults={'_uri': '/apidocs/channels/dev/'}),
    Route('/docs/channels/stable', RedirectHandler,
        defaults={'_uri': '/apidocs/channels/stable/'}),

    Route('<path:.*>', RedirectHandler, defaults={'_uri': redir_old_stable})
  ],
  debug=True)
