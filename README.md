[![Build Status](https://travis-ci.org/garethahealy/fis2-ocp-monitoring.svg?branch=master)](https://travis-ci.org/garethahealy/fis2-ocp-monitoring)
[![License](https://img.shields.io/hexpm/l/plug.svg?maxAge=2592000)]()

# fis2-ocp-monitoring
## Preface
As part of [RedHat Consulting](https://www.redhat.com/en/about/contact/consulting) within the UK and Ireland region, I am typically involved with engagements based around [JBoss Fuse](https://www.redhat.com/en/technologies/jboss-middleware/fuse), 
[JBoss AMQ](https://www.redhat.com/en/technologies/jboss-middleware/amq) and most recently, [OpenShift Container Platform.](https://www.redhat.com/en/technologies/cloud-computing/openshift)
Typically, one of the first questions a customer will ask once they have a basic understanding of a product is; *How do i monitor it?*

This blog post aims to answer that question by putting the jigsaw puzzle together and demonstrating the following:
- Apache Camel running on SpringBoot via [JBoss Fuse Integration Services 2.0 (FIS) for OpenShift*](https://access.redhat.com/documentation/en/red-hat-xpaas/0/single/red-hat-jboss-fuse-integration-services-20-for-openshift/)
- Deployed on [OpenShift Container Platform (OCP) 3.3](https://www.redhat.com/en/technologies/cloud-computing/openshift) with [Hawkular Metrics](http://www.hawkular.org/hawkular-metrics/docs/user-guide/)
- Monitored by [Hawkular OpenShift Agent](https://github.com/hawkular/hawkular-openshift-agent), which will collect metrics via:
    - [Jolokia JMX](https://jolokia.org) 
    - [Prometheus JMX](https://github.com/prometheus/jmx_exporter)
- Visualized by [Hawkular Grafana Datasource](https://github.com/hawkular/hawkular-grafana-datasource)

**NOTE: at time of writing; FIS2.0 is currently in tech-preview.*

The following information expects that the reader has a good understanding of OCP 3.3 and has access to a cluster with metrics already deployed.

### Quickstart example
The example application used is a combination of two quickstart archetypes:

    cdi-camel-jetty-archetype + spring-boot-camel-archetype = {camel-springboot-rest}
    
    mvn archetype:generate \
          -DarchetypeCatalog=https://maven.repository.redhat.com/earlyaccess/all/io/fabric8/archetypes/archetypes-catalog/2.2.180.redhat-000004/archetypes-catalog-2.2.180.redhat-000004-archetype-catalog.xml \
          -DarchetypeGroupId=org.jboss.fuse.fis.archetypes \
          -DarchetypeArtifactId=spring-boot-camel-archetype \
          -DarchetypeVersion=2.2.180.redhat-000004
          -s configuration/settings.xml

The application exposes a simple rest endpoint which responds with a greeting depending on the query parameter provided:

    curl http://localhost:8082/camel/hello?name=Gareth

The application code is located at the below git repo:

    https://github.com/garethahealy/fis2-ocp-monitoring.git

And can be built/run locally by:

    mvn clean install -s configuration/settings.xml
    mvn spring-boot:run -s configuration/settings.xml

### Deploying onto OCP
Now for the interesting part; fitting the jigsaw puzzle pieces together.

#### Deploy camel-springboot-rest
The below commands will create a new project, where we want to import the FIS2.0 ImageStreams and Template:

    oc new-project fis2-monitoring-demo
    oc create -f https://raw.githubusercontent.com/jboss-fuse/application-templates/application-templates-2.0.redhat-000026/fis-image-streams.json
    oc create -f https://raw.githubusercontent.com/garethahealy/fis2-ocp-monitoring/master/ocp-template/openshift.yml
    
Once the ImageStream has been created, we want to import all tags, as we will be using the 2.0 tag as our base image:

    oc import-image fis-java-openshift --all
    
FIS2.0 allows Jolokia access via BasicAuth, by default, a new password is randomly generated on each pod deployment. For our setup, we change this to a known password, firstly by storing the password as a secret:

    echo "supersecretpassword" > jolokia-pw-secret
    oc secrets new jolokia-pw jolokia-pw-secret

And secondly, adjusting the S2I process by creating a symbolic link to the secret mount path:
    
    https://github.com/garethahealy/fis2-ocp-monitoring/blob/master/.s2i/action_hooks/post_assemble#L9

We are now ready to deploy the template:

    oc new-app --template=camel-springboot-rest
    
Once the application has been deployed, a build will be started. You can view the logs via:

    oc logs -f camel-springboot-rest-1-build

Typically, since it is the first build it may take a while to download all of its dependencies, so at this stage i'd suggest going for a coffee.
Once the build has completed a the deployed application needs to be checked its working correctly. The below commands will access the server endpoint and return a greeting message:

    SVCIP=$(oc get svc rest -o jsonpath='{ .spec.portalIP }')
    curl http://$SVCIP:8082/camel/hello?name=test

Now we know the application is working fine in OCP, we want to also check the monitoring endpoints have started correctly:
    
Now we need to check jolokia and promethues are working via:

    RUNNING_POD=$(oc get pods | grep camel-springboot-rest | cut -d' ' -f1)
    POD_IP=$(oc get pod $RUNNING_POD -o jsonpath='{ .status.podIP }')
    curl --insecure -u jolokia:supersecretpassword https://$POD_IP:8778/jolokia/
    curl http://$POD_IP:9779/metrics
    
You might be thinking, but how did we configure Jolokia and Prometheus?
Jolokia is auto-configured as part of the FIS2.0 image so requires no developer input.
Prometheus is added at assemble time and configured via environment variables as per:

    https://github.com/garethahealy/fis2-ocp-monitoring/blob/master/.s2i/action_hooks/post_assemble#L11-L14
    https://github.com/garethahealy/fis2-ocp-monitoring/blob/master/src/main/fabric8/deploymentconfig.yml#L32-L33
    https://github.com/garethahealy/fis2-ocp-monitoring/blob/master/src/main/fabric8/configmapprometheus.yml

At this point, we have a deployed FIS2.0 application that can be monitored but nothing currently activity monitoring it, which is the next step.

#### Deploy Hawkular OpenShift Agent
The Hawkular OpenShift Agent is our method of collection metrics from pods. The agents architecture is one deployed pod per OCP node.
However, firstly we want to check that the Hawkular Metrics is healthy by:

    METRICS_URL=$(oc get route hawkular-metrics -n openshift-infra -o jsonpath='{ .spec.host }')
    curl --insecure --silent https://$METRICS_URL/hawkular/metrics/status 2>&1 | grep "STARTED"

Without the metrics sink, we have nowhere to store collected data.

The agent can be deployed as simply as:

    oc project openshift-infra
    oc adm policy add-cluster-role-to-user cluster-reader system:serviceaccount:openshift-infra:hawkular-agent
    oc create -f https://raw.githubusercontent.com/hawkular/hawkular-openshift-agent/master/deploy/openshift/hawkular-openshift-agent-configmap.yaml -n openshift-infra
    oc process -f https://raw.githubusercontent.com/hawkular/hawkular-openshift-agent/master/deploy/openshift/hawkular-openshift-agent.yaml | oc create -n openshift-infra -f -

We can now check its running:

    AGENT_POD=$(oc get pod | grep hawkular-openshift-agent | cut -d' ' -f1)
    oc logs $AGENT_POD
    
If the agent is collecting metrics correctly, you should see something along the lines of:

    I1222 16:54:10.352794       1 jolokia_metrics_collector.go:82] DEBUG: Told to collect [2] Jolokia metrics from [https://172.17.0.11:8778/jolokia/]
    I1222 16:54:10.353011       1 prometheus_metrics_collector.go:97] DEBUG: Told to collect [2] Prometheus metrics from [http://172.17.0.11:9779/metrics]
    I1222 16:54:10.379166       1 metrics_storage.go:152] DEBUG: Stored datapoints for [2] metrics
    I1222 16:54:10.459964       1 metrics_storage.go:152] DEBUG: Stored datapoints for [2] metrics
    
#### Deploy Hawkular Grafana Datasource:
The final piece to the puzzle is the ability to view the metrics. Thankfully, Hawkular provides a Grafana integration which can be deployed by:

    oc new-project grafana
    oc process -f https://raw.githubusercontent.com/hawkular/hawkular-grafana-datasource/master/docker/openshift/openshift-template-ephemeral.yaml | oc create -n grafana -f -

*NOTE: There is also a *persistent.yml template that can be used*

And much like other steps in this blog, we need to check its running by:

    GRAFANA_URL=$(oc get route hawkular-grafana -n grafana -o jsonpath='{ .spec.host }')
    curl --insecure --silent http://$GRAFANA_URL/login 2>&1 | grep "Grafana"

We can now open $GRAFANA_URL in Chrome, configure the datasource and view the collected metrics.
