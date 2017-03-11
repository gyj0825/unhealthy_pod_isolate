FROM registry.access.redhat.com/jboss-webserver-3/webserver30-tomcat7-openshift:1.2
ENV CHECK_SCRIPT_PATH /opt/app/bin/

ADD launch.sh /opt/webserver/bin/launch.sh

USER 0
RUN mkdir -p $CHECK_SCRIPT_PATH
RUN chown -R 185:185 /opt/webserver/bin/
COPY probe/*  $CHECK_SCRIPT_PATH

USER 185
CMD ["/opt/webserver/bin/launch.sh"]
