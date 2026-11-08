FROM eclipse-temurin:25-jdk-noble AS build
WORKDIR /build
# Resolve dependencies first so they are cached until pom.xml changes.
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN ./mvnw -q -B dependency:go-offline
COPY src src
RUN ./mvnw -q -B package -DskipTests

# Unpack the fat jar into app.jar + lib/: faster class loading, and the layout the AOT cache records.
RUN java -Djarmode=tools -jar target/gateway-java-*.jar extract --destination /app \
 && mv /app/gateway-java-*.jar /app/app.jar

# A JRE with only the modules the app and its libraries use (jdeps finds them),
# plus the ones loaded reflectively that jdeps cannot see.
RUN jdeps --ignore-missing-deps --multi-release 25 --recursive --print-module-deps \
      --class-path '/app/lib/*' /app/app.jar > /build/modules \
 && jlink --add-modules "$(cat /build/modules),jdk.management,jdk.naming.dns" \
      --strip-debug --no-man-pages --no-header-files --compress zip-6 --output /opt/jre

# AOT cache (Java 25, Project Leyden): a training run records loaded and linked classes,
# so real startups skip that work. It must be made by the same JRE, at the same paths.
# The run only starts the Spring context and exits; key and script are throwaway stand-ins.
COPY src/test/resources/test-public.pem /build/train/public.pem
RUN echo 'return {1, 0, 0}' > /build/train/token_bucket.lua \
 && cd /app && JWT_PUBLIC_KEY_FILE=/build/train/public.pem RATE_LIMIT_SCRIPT_FILE=/build/train/token_bucket.lua \
    /opt/jre/bin/java -XX:+UseSerialGC -XX:AOTCacheOutput=/app/app.aot -Dspring.context.exit=onRefresh -jar app.jar

# distroless: glibc and CA certs, no shell or package manager; runs as uid 65532 (nonroot).
FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=build /opt/jre /opt/jre
COPY --from=build /app /app
WORKDIR /app
EXPOSE 8080 9090
ENTRYPOINT ["/opt/jre/bin/java", "-XX:MaxRAMPercentage=75", "-XX:AOTCache=/app/app.aot", "-jar", "/app/app.jar"]
