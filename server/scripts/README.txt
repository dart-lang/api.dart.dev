This contains the scripts used to handle requests to the web site.

- insertname.py: Serves the static HTML modified to include the name
  of the requested object. This makes the static HTML different, so
  the crawler won't de-duplicate all the pages into one.

- redirector.py: The main script, redirects packages to dartdocs.org
  and handles cloud storage requests for the main pages.

- cloudstorage: The cloud storage API code, downloaded from 
https://cloud.google.com/appengine/docs/python/googlecloudstorageclient/download
