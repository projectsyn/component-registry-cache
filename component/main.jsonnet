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

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels: commonLabels {
      SYNMonitoring: 'main',
    },
  },
};

local registry = import 'registry.jsonnet';
local redis = import 'redis.jsonnet';

// Define outputs below
{
  '00_namespace': namespace,
  '10_registry': registry,
  [if params.redis.enabled then '20_redis']: redis,
}
