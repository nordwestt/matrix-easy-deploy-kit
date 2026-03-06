FROM docker:27-cli

RUN apk add --no-cache bash curl openssl python3 git

WORKDIR /opt/matrix-easy-deploy

COPY . .
RUN chmod +x /opt/matrix-easy-deploy/scripts/container-entrypoint.sh \
    && chmod +x /opt/matrix-easy-deploy/matrix-wizard.sh \
    && chmod +x /opt/matrix-easy-deploy/start.sh \
    && chmod +x /opt/matrix-easy-deploy/stop.sh \
    && chmod +x /opt/matrix-easy-deploy/update.sh

ENTRYPOINT ["/opt/matrix-easy-deploy/scripts/container-entrypoint.sh"]
CMD ["bash", "matrix-wizard.sh"]
