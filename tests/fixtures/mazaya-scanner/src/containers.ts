// Source parsing is static-only: no constructors are executed.
const db = new GenericContainer("postgres:16-alpine");
const image = DockerImageName.parse("mysql:8.0.46");
