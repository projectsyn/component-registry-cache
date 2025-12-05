// main template for registry-cache
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.registry_cache;

local commonLabels = {
  'app.kubernetes.io/name': 'registry-cache',
  'app.kubernetes.io/managed-by': 'commodore',
  'app.kubernetes.io/part-of': 'syn',
};

local redisConfig = kube.ConfigMap('redis-config') {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      'app.kubernetes.io/component': 'redis',
    },
  },
  data: {
    'redis.conf': params.redis.config,
  },
};

local redisDeployment = kube.Deployment('redis') {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      'app.kubernetes.io/component': 'redis',
    },
  },
  spec+: {
    replicas: 1,
    template+: {
      spec+: {
        containers_+: {
          redis: kube.Container('redis') {
            image: '%(registry)s/%(repository)s:%(tag)s' % params.images.redis,
            command: [
              'redis-server --appendonly yes --maxmemory $$(( $$( cat /sys/fs/cgroup/memory.max ) - 100000000)) --maxmemory-policy allkeys-lru',
              '/etc/redis/redis.conf',
            ],
            ports_+: {
              http: {
                containerPort: 6379,
              },
            },
            volumeMounts: [
              {
                mountPath: '/etc/redis',
                name: 'config',
              },
            ],
            resources: params.redis.resources,
            livenessProbe: {
              tcpSocket: {
                port: 6379,
              },
              initialDelaySeconds: 0,
              timeoutSeconds: 5,
              periodSeconds: 5,
              failureThreshold: 5,
              successThreshold: 1,
            },
            readinessProbe: {
              exec: {
                command: [
                  'redis-cli',
                  'ping',
                ],
              },
              initialDelaySeconds: 20,
              timeoutSeconds: 5,
              periodSeconds: 5,
              failureThreshold: 5,
              successThreshold: 1,
            },
          },
        },
        [if params.imagePullSecretName != null then 'imagePullSecrets']: [
          {
            name: params.imagePullSecretName,
          },
        ],
        volumes: [ {
          configMap: {
            defaultMode: 420,
            name: redisConfig.metadata.name,
          },
          name: 'config',
        } ],
      },
    },
  },
};

local redisService = kube.Service('redis') {
  metadata+: {
    namespace: params.namespace,
    labels: commonLabels {
      name: params.namespace,
      'app.kubernetes.io/component': 'redis',
    },
  },
  spec+: {
    ports: [ {
      port: 6379,
    } ],
    selector: {
      'app.kubernetes.io/component': 'redis',
    },
  },
};

[
  redisConfig,
  redisDeployment,
  redisService,
]
