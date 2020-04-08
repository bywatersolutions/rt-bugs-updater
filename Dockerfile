FROM alpine:3

WORKDIR /app

RUN apk add --no-cache \
    perl \
    perl-app-cpanminus \
    perl-dev \
    wget \
    build-base

# Copy all files to workdir
COPY . .

RUN cpanm --installdeps . 
RUN cpanm https://github.com/kylemhall/BZ-Client-REST.git

CMD ./rt-bugs-updater.pl -v
