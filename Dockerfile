FROM alpine:3

WORKDIR /app

RUN apk add --no-cache \
    build-base \
    openssl \
    openssl-dev \
    perl \
    perl-app-cpanminus \
    perl-dev \
    wget \
    zlib-dev

# Copy all files to workdir
COPY . .

RUN cpanm --installdeps . 
RUN cpanm https://github.com/kylemhall/BZ-Client-REST.git

CMD ./rt-bugs-updater.pl -v
