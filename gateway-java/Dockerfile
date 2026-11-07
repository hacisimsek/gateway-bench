FROM eclipse-temurin:25-jdk-noble AS build
WORKDIR /app
# Resolve dependencies first so they are cached until pom.xml changes.
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN ./mvnw -q -B dependency:go-offline
COPY src src
RUN ./mvnw -q -B package -DskipTests

FROM eclipse-temurin:25-jre-noble
COPY --from=build /app/target/gateway-java-*.jar /app/app.jar
USER 65534
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
