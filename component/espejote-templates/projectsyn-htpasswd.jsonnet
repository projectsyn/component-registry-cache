local esp = import 'espejote.libsonnet';

local config = import 'projectsyn-htpasswd/config.json';

local token_secrets = esp.context().token_secrets;

local bcrypt(password, salt) =
  local h = esp.ALPHA.bcrypt(password, salt);
  if h[1] != null then
    error 'Error in Espejote bcrypt() native function: %s' % h[1]
  else
    h[0];

local cluster_passwords = std.foldl(
  function(tokens, secret)
    local new_tokens = std.foldl(
      function(ts, cluster)
        if std.objectHas(tokens, cluster) then
          error "Duplicate username '%s'" % cluster
        else
          ts {
            [cluster]: std.base64Decode(secret.data[cluster]),
          },
      std.objectFields(secret.data),
      {}
    );
    tokens + new_tokens,
  token_secrets,
  {}
);

local htpasswd_entries = [
  '%(cluster)s:%(pw_bcrypt)s' % {
    cluster: cluster_key,
    pw_bcrypt: bcrypt(
      cluster_passwords[cluster_key],
      std.sha256(cluster_key)[-16:]
    ),
  }
  for cluster_key in std.objectFields(cluster_passwords)
];

local htpasswd_secret = {
  apiVersion: 'v1',
  kind: 'Secret',
  type: 'Opaque',
  metadata: {
    name: config.secretName,
  },
  stringData: {
    htpasswd: std.join('\n', htpasswd_entries) + '\n',
  },
};

[
  htpasswd_secret,
  {
    apiVersion: 'apps/v1',
    kind: 'Deployment',
    metadata: {
      name: 'registry',
    },
    spec: {
      template: {
        metadata: {
          annotations: {
            ['%s/checksum' % config.secretName]: std.sha256(std.manifestJsonMinified(htpasswd_secret)),
          },
        },
      },
    },
  },
]
