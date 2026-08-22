var proxy = 'PROXY 10.100.0.1:3128';
var directDomains = [
  'internal.example.com'
];
var proxyDomains = [
  'google.com',
  'github.com'
];

function domainMatches(host, domain) {
  return host === domain ||
    (host.length > domain.length &&
      host.slice(-(domain.length + 1)) === '.' + domain);
}

function anyDomainMatches(host, domains) {
  for (var index = 0; index < domains.length; index += 1) {
    if (domainMatches(host, domains[index])) {
      return true;
    }
  }

  return false;
}

function FindProxyForURL(url, host) {
  host = (host || '').toLowerCase();

  if (anyDomainMatches(host, directDomains)) {
    return 'DIRECT';
  }

  if (anyDomainMatches(host, proxyDomains)) {
    return proxy;
  }

  return 'DIRECT';
}
