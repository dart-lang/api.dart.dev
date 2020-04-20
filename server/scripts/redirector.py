# Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

import logging
import re
import json
from webapp2 import *
from webapp2_extras.routes import DomainRoute
from datetime import datetime, timedelta
from google.appengine.ext import blobstore
from google.appengine.ext.webapp import blobstore_handlers
from google.appengine.api import memcache
import cloudstorage

ONE_HOUR = 60 * 60
ONE_DAY = ONE_HOUR * 24
ONE_WEEK = ONE_DAY * 7

# for redirects below
ONLY_DART_LIB = re.compile("^dart:([a-zA-Z0-9_]+)$")
LIB_NAME_AND_CLASS_NAME = re.compile("^dart[:-]([^\.]+)\.(.+)$")

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
  GOOGLE_STORAGE = '/dartlang-api-docs/channels'
  GOOGLE_STORAGE_NEW = '/dartlang-api-docs/gen-dartdocs'
  PRETTY_VERSION_LOCATION = (
      '/dart-archive/channels/%(channel)s/raw/%(rev)s/VERSION')

  def version_file_loc(self, channel):
    return '%s/%s/latest.txt' % (ApiDocs.GOOGLE_STORAGE, channel)

  # Dictionary of versions holding version information of the latest recorded
  # version number and the time when it was recorded.
  latest_versions = {
    'be': VersionInfo(timedelta(minutes=30)),
    'dev': VersionInfo(timedelta(hours=6)),
    'beta': VersionInfo(timedelta(hours=12)),
    'stable': VersionInfo(timedelta(days=1)),
  }

  def recheck_latest_version(self, channel):
    """Check Google storage to determine the latest version file in a given
    channel."""
    data = None
    version_file_location = self.version_file_loc(channel)
    with cloudstorage.open(version_file_location, 'r') as f:
        line = f.readline()
        data = line.replace('\x00', '')
        ApiDocs.latest_versions[channel].last_check = datetime.now()
    revision = data
    ApiDocs.latest_versions[channel].version = revision
    return revision

  def get_latest_version(self, channel):
    """Determine what the latest version number is for this particular channel.
    We do a bit of caching so that we're not constantly pinging for the latest
    version of stable, for example."""
    forced_reload = (self.request and self.request.get('force_reload'))
    version_info = ApiDocs.latest_versions[channel]
    if (forced_reload or
        version_info.version is None or version_info.should_update()):
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
    with cloudstorage.open(version_file_location, 'r') as f:
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
    suffix = channel
    if channel == 'be':
      suffix = 'builds'
    index = version_num.find('.')
    if index != -1:
      nums = version_num.split('.')
      release_num = nums[1]
      if nums[0] == '1' and int(release_num) < 15:
        return '%s/%s/%s' % (ApiDocs.GOOGLE_STORAGE_NEW, version_num, postfix)
    return '%s/%s/%s/%s' % (ApiDocs.GOOGLE_STORAGE_NEW, suffix, version_num, postfix)

  def resolve_doc_path(self, channel):
    """Given the request URL, determine what specific docs version we should
    actually display."""
    path = None

    if channel:
      length = len(channel) + 2
    else:
      length = 1
    postfix = self.request.path[length:]
    index = postfix.find('/')
    if index != -1:
      version_num = postfix[:index]
      postfix = postfix[index+1:]
      if postfix.startswith('/'):
        postfix = postfix[1:]
    else:
      if channel:
        version_num = self.get_latest_version(channel)
      else:
        channel = 'stable'
        version_num = self.get_latest_version(channel)
      postfix = 'index.html'
    path = self.build_gcs_path(version_num, postfix, channel)
    logging.debug('build_gcs_path("%s", "%s", "%s") -> "%s"'
                  % (version_num, postfix, channel, path))
    return path

  def get_channel(self):
    """Quick accessor to examine a request and determine what channel
    (be/beta/dev/stable) we're looking at. Return None if we have a weird
    unexpected URL."""
    parts = self.request.path.split('/')
    if len(parts) > 0:
      if len(parts) > 3 and self.request.path.startswith('/apidocs/channels/'):
        channel = parts[3] # ['', 'apidocs', 'channels', '<channel>', ...]
      else:
        channel = parts[1] # ['', '<channel>', ...]
      if channel in ApiDocs.latest_versions:
        return channel
    return None

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

    # this is serving all paths, so check to make sure version is valid pattern
    # else redirect to stable
    # /dev/1.15.0-dev.5.1/index.html
    if channel:
      length = len(channel) + 2
    else:
      length = 1
    request = self.request.path[length:]

    index = request.find('/')
    if index != -1:
      version_num = request[:index]
      match = re.match(r'^-?[0-9]+$', version_num)
      if match:
        if int(version_num) > 136051:
          path = request[index+1:]
          if not channel:
            return self.redirect('/be/%s/%s' % (version_num, path))
        else:
          return self.redirect('/stable')
      else:
        match = re.match(r'(\d+\.){2}\d+([\+-]([\.a-zA-Z0-9-\+])*)?', version_num)
        latest = self.get_latest_version(channel or 'stable')
        if match:
          if not channel:
            return self.redirect('/stable/%s/index.html' % latest)
        else:
          return self.redirect('/%s/%s/%s' % (channel or 'stable', latest, request))
    else:
      match = re.match(r'(\d+\.){2}\d+([\+-]([\.a-zA-Z0-9-\+])*)?', request)
      if match:
        return self.redirect('/%s/index.html' % request)
      else:
        return self.redirect('/stable')

    my_path = self.resolve_doc_path(channel)

    gcs_path = '/gs%s' % my_path
    if not gcs_path:
      self.error(404)
      return

    gs_key = blobstore.create_gs_key(gcs_path)
    age = self.get_cache_age(gcs_path)

    self.response.headers['Cache-Control'] = 'max-age=' + \
       str(age) + ',s-maxage=' + str(age)

    self.response.headers['Access-Control-Allow-Origin'] = '*'

    # is there a better way to check if a file exists in cloud storage?
    # AE will serve a 500 if the file doesn't exist, but that should
    # be a 404

    path_exists = memcache.get(gcs_path)
    if path_exists == "1":
        self.send_blob(gs_key)
    else:
      try:
        # just check for existence
        cloudstorage.open(my_path, 'r').close()
        memcache.add(key=gcs_path, value="1", time=ONE_DAY)
        self.send_blob(gs_key)
      except Exception:
        memcache.add(key=gcs_path, value="0", time=ONE_DAY)
        logging.debug('Could not open ' + gcs_path + ', sending 404')
        self.error(404)

def redir_dom(handler, *args, **kwargs):
  return '/stable/dart-html/index.html'

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
  return '/' + channel

def redir_old_be(handler, *args, **kwargs):
  return redir_old(kwargs, 'be')

def redir_old_dev(handler, *args, **kwargs):
  return redir_old(kwargs, 'dev')

def redir_old_stable(handler, *args, **kwargs):
  return redir_old(kwargs, 'dev')

def redir_channel_latest(channel, postfix):
  apidocs = ApiDocs()
  version_num = apidocs.get_latest_version('%s' % channel)
  return '/%s/%s/%s' % (channel, version_num, postfix)

def redir_stable_latest(handler, *args, **kwargs):
  return redir_channel_latest('stable', 'index.html')

def redir_dev_latest(handler, *args, **kwargs):
  return redir_channel_latest('dev', 'index.html')

def redir_beta_latest(handler, *args, **kwargs):
  return redir_channel_latest('beta', 'index.html')

def redir_be_latest(handler, *args, **kwargs):
  return redir_channel_latest('be', 'index.html')

def redir_stable_path(handler, *args, **kwargs):
  postfix = kwargs['path'][1:]
  return redir_channel_latest('stable', postfix)

def redir_dev_path(handler, *args, **kwargs):
  postfix = kwargs['path'][1:]
  return redir_channel_latest('dev', postfix)

def redir_beta_path(handler, *args, **kwargs):
  postfix = kwargs['path'][1:]
  return redir_channel_latest('beta', postfix)

def redir_be_path(handler, *args, **kwargs):
  postfix = kwargs['path'][1:]
  return redir_channel_latest('be', postfix)

# /apidocs/channels/stable/dartdoc-viewer/home => /stable
# /apidocs/channels/stable/dartdoc-viewer/dart:math => /stable/dart-math/dart-math-library.html
# /apidocs/channels/stable/dartdoc-viewer/dart[:-]async.Future => /stable/dart-async/Future-class.html
def redir_name(handler, *args, **kwargs):
  channel = kwargs['channel']
  postfix = kwargs['path'][1:]

  # /apidocs/channels/stable/dartdoc-viewer/home => /stable
  # /apidocs/channels/stable/dartdoc-viewer/ => /stable
  # /apidocs/channels/stable/dartdoc-viewer => /stable
  if postfix == 'home' or postfix == '':
    return '/%s' % (channel)

  # /apidocs/channels/stable/dartdoc-viewer/dart:math => /stable/dart-math/dart-math-library.html
  is_lib_page = ONLY_DART_LIB.match(postfix)
  if is_lib_page:
    name = postfix.replace(':', '-')
    return '/%s/%s/%s-library.html' % (channel, name, name)

  # /apidocs/channels/stable/dartdoc-viewer/dart[:-]async.Future => /stable/dart-async/Future-class.html
  is_lib_and_class = LIB_NAME_AND_CLASS_NAME.match(postfix)
  if is_lib_and_class:
    lib_name = 'dart-' + is_lib_and_class.group(1)
    class_name = is_lib_and_class.group(2)
    return '/%s/%s/%s-class.html' % (channel, lib_name, class_name)

  abort(404)

def redir_bare_lib_name(handler, *args, **kwargs):
  version = kwargs['version']
  libname = kwargs['libname']

  # /1.12.0/dart-async => /1.12.0/dart-async/dart-async-library.html
  return '/%s/dart-%s/dart-%s-library.html' % (version, libname, libname)

# /dart_core.html => /stable/dart-core/dart-core-library.html
def redir_legacy_lib(handler, *args, **kwargs):
  libname = kwargs['libname']
  return '/stable/dart-%s/dart-%s-library.html' % (libname, libname)

# /dart_core/Iterable.html => /stable/dart-core/Iterable-class.html
def redir_legacy_lib_class(handler, *args, **kwargs):
    libname = kwargs['libname']
    classname = kwargs['classname']
    return '/stable/dart-%s/%s-class.html' % (libname, classname)

def redir_apidartdev(handler, *args, **kwargs):
    return 'https://api.dart.dev/%s' % (kwargs['path'])

application = WSGIApplication(
  [
    # Legacy domain name, redirect to new domain
    DomainRoute('api.dartlang.org', [
        Route('/<path:.*>', RedirectHandler,
            defaults={'_uri': redir_apidartdev}),
    ]),
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
        defaults={'_uri': '/be'}),

    # Data requests go to cloud storage
    Route('/apidocs/channels/be/docs<path:.*>', RedirectHandler,
        defaults={'_uri': '/be'}),
    Route('/apidocs/channels/beta/docs<path:.*>', RedirectHandler,
        defaults={'_uri': '/beta'}),
    Route('/apidocs/channels/dev/docs<path:.*>', RedirectHandler,
        defaults={'_uri': '/dev'}),
    Route('/apidocs/channels/stable/docs<path:.*>', RedirectHandler,
        defaults={'_uri': '/stable'}),

    Route('/stable/',  RedirectHandler,
        defaults={'_uri': '/stable'}),
     Route('/latest',  RedirectHandler,
        defaults={'_uri': '/stable'}),
    Route('/dev/',  RedirectHandler,
        defaults={'_uri': '/dev'}),
    Route('/beta/',  RedirectHandler,
        defaults={'_uri': '/beta'}),
    Route('/be/',  RedirectHandler,
        defaults={'_uri': '/be'}),
    Route('/bleeding_edge',  RedirectHandler,
        defaults={'_uri': '/be'}),

     Route('/stable/latest', RedirectHandler,
        defaults={'_uri': '/stable'}),
    Route('/dev/latest', RedirectHandler,
        defaults={'_uri': '/dev'}),
    Route('/beta/latest', RedirectHandler,
        defaults={'_uri': '/beta'}),
    Route('/be/latest', RedirectHandler,
        defaults={'_uri': '/be'}),

    Route('/dart_<libname:[\w]+>.html', RedirectHandler,
        defaults={'_uri': redir_legacy_lib}),

    Route('/dart_<libname:[\w]+>/<classname:[\w]+>.html', RedirectHandler,
        defaults={'_uri': redir_legacy_lib_class}),

    # temp routing till stable docs are rolled out
    Route('/stable', RedirectHandler,
        defaults={'_uri': redir_stable_latest}), #ApiDocs),
    Route('/dev', RedirectHandler,
        defaults={'_uri': redir_dev_latest}), #ApiDocs),
    Route('/beta', RedirectHandler,
        defaults={'_uri': redir_beta_latest}),#ApiDocs),
    Route('/be', RedirectHandler,
        defaults={'_uri': redir_be_latest}),#ApiDocs),

    Route('/apidocs/channels/<channel:stable|dev|be>/dartdoc-viewer<path:.*>',
        RedirectHandler,
        defaults={'_uri': redir_name}),

    Route('/docs/continuous<path:.*>', RedirectHandler,
        defaults={'_uri': '/be'}),
    Route('/docs/releases/latest<path:.*>', RedirectHandler,
        defaults={'_uri': '/stable'}),

     # Legacy handling: redirect old doc links to apidoc.
    Route('/docs/channels/be/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_old_be}),
    Route('/docs/channels/dev/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_old_dev}),
    Route('/docs/channels/stable/latest<path:.*>', RedirectHandler,
        defaults={'_uri': redir_old_stable}),
    Route('/docs/channels/be', RedirectHandler,
        defaults={'_uri': '/be'}),
    Route('/docs/channels/dev', RedirectHandler,
        defaults={'_uri': '/dev'}),
    Route('/docs/channels/stable', RedirectHandler,
        defaults={'_uri': '/stable'}),

    Route('/<version:[\w.-]+>/dart-<libname:\w+>', RedirectHandler,
        defaults={'_uri': redir_bare_lib_name}),

    Route('/', RedirectHandler, defaults={'_uri': '/stable'}),

    Route('<path:.*>', ApiDocs)
  ],
  debug=True)
