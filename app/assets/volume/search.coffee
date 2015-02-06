'use strict'

app.controller 'volume/search', [
  '$scope', '$location', 'constantService', 'displayService', 'volumes',
  ($scope, $location, constants, display, volumes) ->
    limit = 12 # server-side default
    offset = $location.search().offset ? 0
    display.title = 'Search'
    $scope.volumes = volumes
    $scope.page = 1 + (offset / limit)
    if volumes.length > limit
      $scope.next = -> $location.search('offset', limit + offset)
      $scope.volumes.pop()
    if offset > 0
      $scope.prev = -> $location.search('offset', Math.max(0, offset - limit))
    return
]