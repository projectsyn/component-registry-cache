// main template for registry-cache
local kube = import 'kube-ssa-compat.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local com = import 'lib/commodore.libjsonnet';

// The hiera parameters for the component
local inv = kap.inventory();
local params = inv.parameters.registry_cache;

local commonLabels = {
  'app.kubernetes.io/name': 'registry-cache',
  'app.kubernetes.io/managed-by': 'commodore',
  'app.kubernetes.io/part-of': 'syn',
};

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels: commonLabels + com.makeMergeable(params.namespaceLabels),
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
