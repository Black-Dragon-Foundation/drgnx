var request = require("supertest");

describe("app", function () {
  it("answers with 200 on the root path", function (done) {
    request(app).get("/").expect(200, done);
  });

  it("answers with 404 on an unknown path", function (done) {
    request(app).get("/nothing-here").expect(404, done);
  });

  it("sets the content type of a JSON answer", function (done) {
    request(app).get("/json").expect("Content-Type", /json/, done);
  });

  it("keeps the query string of a redirect", function (done) {
    request(app).get("/old?x=1").expect("Location", "/new?x=1", done);
  });
});
