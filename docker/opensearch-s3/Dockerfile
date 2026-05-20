FROM opensearchproject/opensearch:3.6.0

RUN /usr/share/opensearch/bin/opensearch-plugin install --batch repository-s3

COPY --chown=opensearch:opensearch --chmod=0755 docker/opensearch-s3/docker-entrypoint-s3.sh /usr/share/opensearch/docker-entrypoint-s3.sh

ENTRYPOINT ["/usr/share/opensearch/docker-entrypoint-s3.sh"]
CMD ["opensearch"]
