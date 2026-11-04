local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local esp = import 'lib/espejote.libsonnet';
local eso = import 'lib/external-secrets-operator.libsonnet';

local inv = kap.inventory();
local params = inv.parameters.registry_cache;

local synhtpasswd = params.projectsynHtpasswd;

local token_secret_name = '%s-client-tokens' % synhtpasswd.secretName;

local lieutenant_instances = std.prune(synhtpasswd.lieutenantInstances);

local lieutenant_token_secret =
  kube.Secret('%s-lieutenant-tokens' % synhtpasswd.secretName) {
    metadata+: {
      namespace: params.namespace,
    },
    stringData: {
      [name]: synhtpasswd.lieutenantInstances[name].token
      for name in std.objectFields(lieutenant_instances)
    },
  };

local lieutenant_secret_stores = [
  eso.SecretStore(name) {
    metadata+: {
      namespace: params.namespace,
    },
    spec: {
      provider: {
        kubernetes: {
          auth: {
            token: {
              bearerToken: {
                name: lieutenant_token_secret.metadata.name,
                key: name,
              },
            },
          },
          remoteNamespace:
            std.get(lieutenant_instances[name], 'lieutenantNamespace', 'lieutenant'),
          server: {
            url: lieutenant_instances[name].kubernetesUrl,
          },
        },
      },
    },
  }
  for name in std.objectFields(lieutenant_instances)
];

local cluster_tokens_externalsecret = [
  eso.ExternalSecret('%s-cluster-tokens' % synhtpasswd.secretName) {
    metadata+: {
      namespace: params.namespace,
    },
    spec: {
      refreshInterval: synhtpasswd.clusterTokenRefreshInterval,
      target: {
        name: token_secret_name,
        template: {
          engineVersion: 'v2',
          templateFrom: [
            {
              target: 'Data',
              // NOTE(sg): This can be simplified by removing the
              // `isClusterToken` predicate once we have an accurate way to
              // select only steward token secrets from each secret store.
              literal: |||
                {{- $htpasswd := list }}
                {{- range $key, $val := . }}
                {{- $json := $val | fromJson }}
                {{- $isClusterToken := (and ((hasSuffix "-api-token" $key) | not) ((contains "-token-" $key) |not)) }}
                {{- if $isClusterToken }}
                {{ $key }}: {{ $json.token | sha256sum }}
                {{- end }}
                {{- end }}
              |||,
              valuesDecodingStrategy: 'None',
            },
          ],
        },
      },
      dataFrom: [
        local storeCfg = synhtpasswd.lieutenantInstances[store.metadata.name];
        {
          find: {
            conversionStrategy: 'Default',
            decodingStrategy: 'None',
            name: {
              // TODO(sg): Switch to label match once the steward token
              // secrets are labeled.
              regexp: '^c-.*',
            },
          },
          [if std.get(storeCfg, 'userPrefix', '') != '' then 'rewrite']: [
            {
              regexp: {
                source: '(.*)',
                target: '%s$1' % storeCfg.userPrefix,
              },
            },
          ],
          sourceRef: {
            storeRef: {
              kind: store.kind,
              name: store.metadata.name,
            },
          },
        }
        for store in lieutenant_secret_stores
      ],
    },
  },
];

local htpasswd_managed_resource =
  local rbac_name = '%s-manager' % synhtpasswd.secretName;
  local sa = kube.ServiceAccount(rbac_name) {
    metadata+: {
      namespace: params.namespace,
    },
  };
  local jlib = esp.jsonnetLibrary('projectsyn-htpasswd', params.namespace) {
    spec: {
      data: {
        'config.json': std.manifestJsonMinified({
          secretName: synhtpasswd.secretName,
        }),
      },
    },
  };
  local role = kube.Role(rbac_name) {
    metadata+: {
      namespace: params.namespace,
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ token_secret_name ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ '' ],
        resources: [ 'secrets' ],
        resourceNames: [ synhtpasswd.secretName ],
        verbs: [ 'get', 'list', 'watch', 'create', 'update', 'patch' ],
      },
      {
        apiGroups: [ 'espejote.io' ],
        resources: [ 'jsonnetlibraries' ],
        resourceNames: [ jlib.metadata.name ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'apps' ],
        resources: [ 'deployments' ],
        resourceNames: [ 'registry' ],
        verbs: [ 'patch' ],
      },
    ],
  };
  local rolebinding = kube.RoleBinding(rbac_name) {
    metadata+: {
      namespace: params.namespace,
    },
    roleRef_: role,
    subjects_: [ sa ],
  };

  [
    esp.managedResource(synhtpasswd.secretName, params.namespace) {
      spec: {
        serviceAccountRef: {
          name: sa.metadata.name,
        },
        context: [
          {
            // NOTE(sg): The template doesn't make an assumption that this
            // context matches exactly one token.
            name: 'token_secrets',
            resource: {
              apiVersion: 'v1',
              kind: 'Secret',
              name: token_secret_name,
              namespace: params.namespace,
            },
          },
        ],
        triggers: [
          {
            name: 'config',
            watchResource: {
              apiVersion: jlib.apiVersion,
              kind: jlib.kind,
              name: jlib.metadata.name,
              namespace: jlib.metadata.namespace,
            },
          },
          {
            name: 'htpasswd_secret',
            watchResource: {
              apiVersion: 'v1',
              kind: 'Secret',
              name: synhtpasswd.secretName,
              namespace: params.namespace,
            },
          },
          {
            name: 'token_secret',
            watchContextResource: {
              name: 'token_secrets',
            },
          },
        ],
        template: importstr 'espejote-templates/projectsyn-htpasswd.jsonnet',
      },
    },
    jlib,
    sa,
    role,
    rolebinding,
  ];

if (
  !std.member(inv.applications, 'external-secrets-operator') ||
  !std.member(inv.applications, 'espejote')
) then
  error "The 'projectsyn htpasswd' feature of component-registry-cache requires components espejote and external-secrets-operator!"
else
  [ lieutenant_token_secret ]
  + lieutenant_secret_stores
  + cluster_tokens_externalsecret
  + htpasswd_managed_resource
