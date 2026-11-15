FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY cmd/synthetic ./cmd/synthetic

ARG TARGETOS
ARG TARGETARCH
ARG VERSION
ARG SOURCE_SHA

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath \
    -ldflags "-s -w -X main.version=$VERSION -X main.sourceSHA=$SOURCE_SHA" \
    -o /out/synthetic ./cmd/synthetic

FROM scratch
ARG VERSION
ARG SOURCE_SHA
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$SOURCE_SHA
COPY --from=build /out/synthetic /synthetic
ENTRYPOINT ["/synthetic"]
