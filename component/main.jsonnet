// main template for registry-cache
local kube = import 'kube-ssa-compat.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';

// The hiera parameters for the component
local inv = kap.inventory();
local params = inv.parameters.registry_cache;

local isOpenshift = std.member([ 'openshift4', 'oke' ], inv.parameters.facts.distribution);

local commonLabels = {
  'app.kubernetes.io/name': 'registry-cache',
  'app.kubernetes.io/managed-by': 'commodore',
  'app.kubernetes.io/part-of': 'syn',
};

local namespace = kube.Namespace(params.namespace) {
  metadata+: {
    labels: commonLabels {
      // Configure the namespaces so that the OCP4 cluster-monitoring
      // Prometheus can find the servicemonitors and rules.
      [if isOpenshift then 'openshift.io/cluster-monitoring']: 'true',
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
