// main template for registry-cache
local kube = import 'kube-ssa-compat.libsonnet';
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local prom = import 'lib/prom.libsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.registry_cache;

local commonLabels = {
  'app.kubernetes.io/name': 'registry-cache',
  'app.kubernetes.io/managed-by': 'commodore',
  'app.kubernetes.io/part-of': 'syn',
};

local pullSecret =
  if std.objectHas(params.registry, 'pullSecretName') then
    std.trace(
      'Parameter `registry.pullSecretName` is deprecated,'
      + ' please use parameter `imagePullSecretName` instead',
      params.registry.pullSecretName
    )
  else
    params.imagePullSecretName;

// see: https://docs.docker.com/registry/configuration/
local config = params.registry.config {
  version: '0.1',
  [if params.htpasswd != null then 'auth']+: {
    htpasswd: {
      realm: 'docker-registry-realm',
      path: '/etc/docker/registry/htpasswd',
    },
  },
  http+: {
    debug: {
      addr: '0.0.0.0:6000',
      prometheus: {
        enabled: true,
        path: '/metrics',
      },
    },
  },
  storage+: {
    cache: {
      blobdescriptor: if params.redis.enabled then 'redis' else 'inmemory',
    },
  },
  [if params.redis.enabled then 'redis']: {
    addrs: [ 'redis:6379' ],
  },
};

local registryPullSecret = kube.Secret('registry-pull-secret') {
  metadata+: {
    namespace: params.namespace,
    name: params.imagePullSecretName,
    labels: commonLabels {
      'app.kubernetes.io/component': 'registry',
      'app.kubernetes.io/name': 'registry-pull-secret',
    },
  },
} + com.makeMergeable(params.imagePullSecret);

local registryConfig = kube.Secret('registry-config') {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      'app.kubernetes.io/component': 'registry',
    },
  },
  stringData: {
    'config.yml': std.manifestYamlDoc(config),
    [if params.htpasswd != null then 'htpasswd']: params.htpasswd,
  },
};

local registryDeployment = kube.Deployment('registry') {
  metadata+: {
    annotations+: {
      'checksum/config': std.md5(std.manifestJsonMinified(registryConfig.data)),
    },
    labels: commonLabels {
      'app.kubernetes.io/component': 'registry',
    },
    namespace: params.namespace,
  },
  spec+: {
    replicas: std.get(params, 'replicas', params.registry.replicas),
    template+: {
      spec+: {
        containers_+: {
          registry: kube.Container('registry') {
            image: '%(registry)s/%(repository)s:%(tag)s' % params.images.registry,
            args: [
              'serve',
              '/etc/distribution/config.yml',
            ],
            ports_: {
              http: {
                containerPort: 5000,
              },
              metrics: {
                containerPort: 6000,
              },
            },
            volumeMounts_: {
              config: {
                mountPath: '/etc/distribution',
              },
            },
            resources: params.registry.resources,
          },
        },
        [if pullSecret != null then 'imagePullSecrets']: [
          {
            name: pullSecret,
          },
        ],
        volumes_: {
          config: {
            secret: {
              secretName: registryConfig.metadata.name,
            },
          },
        },
      },
    },
  },
};

local registryService = kube.Service('registry') {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      'app.kubernetes.io/component': 'registry',
    },
  },
  spec+: {
    ports: [ {
      name: 'http',
      port: 5000,
    }, {
      name: 'metrics',
      port: 6000,
    } ],
    selector: {
      'app.kubernetes.io/component': 'registry',
    },
  },
};

local registryMonitor = kube._Object('monitoring.coreos.com/v1', 'ServiceMonitor', 'registry-cache') {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      'app.kubernetes.io/component': 'registry',
    },
  },
  spec: {
    endpoints: [ {
      port: 'metrics',
      path: '/metrics',
      interval: '60s',
      scrapeTimeout: '30s',
    } ],
    jobLabel: 'registry-cache',
    namespaceSelector: {
      matchNames: [ params.namespace ],
    },
    selector: {
      matchLabels: commonLabels {
        'app.kubernetes.io/component': 'registry',
      },
    },
  },
};

local registryAlerts = prom.generateRules('registry-cache', params.rules) {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      'app.kubernetes.io/component': 'registry',
    },
  },
};

local registryExpose = if params.expose_type == 'ingress' then
  kube.Ingress('registry') {
    apiVersion: 'networking.k8s.io/v1',
    metadata+: {
      namespace: params.namespace,
      annotations+: {
        'cert-manager.io/cluster-issuer': 'letsencrypt-production',
      },
      labels: commonLabels {
        'app.kubernetes.io/component': 'registry',
      },
    },
    spec: {
      tls: [ {
        hosts: [ params.fqdn ],
        secretName: 'registry-tls',
      } ],
      rules: [ {
        host: params.fqdn,
        http: {
          paths: [ {
            path: '/',
            pathType: 'Prefix',
            backend: {
              service: {
                name: registryService.metadata.name,
                port: {
                  name: 'http',
                },
              },
            },
          } ],
        },
      } ],
    },
  }
else if params.expose_type == 'route' then
  kube._Object('route.openshift.io/v1', 'Route', 'registry') {
    metadata+: {
      namespace: params.namespace,
      annotations+: {
        'kubernetes.io/tls-acme': 'true',
      },
      labels: commonLabels {
        'app.kubernetes.io/component': 'registry',
      },
    },
    spec: {
      host: params.fqdn,
      tls: {
        insecureEdgeTerminationPolicy: 'Redirect',
        termination: 'edge',
      },
      to: {
        kind: 'Service',
        name: 'registry',
      },
    },
  }
else
  error 'parameters.registry_cache.expose_type must be either "route" or "ingress"'
;

[
  registryConfig,
  registryDeployment,
  registryService,
  registryMonitor,
  registryExpose,
]
+ if std.length(params.rules) > 0 then [ registryAlerts ] else []
                                                               + if params.imagePullSecret != null then [ registryPullSecret ] else []
