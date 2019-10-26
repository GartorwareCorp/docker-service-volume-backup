FROM ubuntu:18.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl cron awscli \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* 

# https://docs.docker.com/engine/installation/linux/docker-ce/ubuntu/#install-using-the-convenience-script
RUN curl -fsSL get.docker.com -o get-docker.sh \
    && sh get-docker.sh

COPY ./src/entrypoint.sh /root/
COPY ./src/backup.sh /root/
COPY ./src/restore.sh /root/
RUN chmod a+x /root/entrypoint.sh
RUN chmod a+x /root/backup.sh
RUN chmod a+x /root/restore.sh

WORKDIR /root
CMD [ "/root/entrypoint.sh" ]
