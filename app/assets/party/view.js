'use strict';

app.controller('party/view', [
  '$scope', 'displayService', 'party',
  function ($scope, display, party) {
    $scope.party = party;
    display.title = party.name;
  }
]);
