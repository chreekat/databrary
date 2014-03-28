define(['config/module'], function (module) {
	'use strict';

	module.controller('TagsPanel', ['$scope', 'Tag', '$route', 'MessageService', 'Volume', '$cacheFactory', function ($scope, Tag, $route, messageService, Volume, $cacheFactory) {
		var DEFAULT_MESSAGE = {
			type: 'alert',
			countdown: 3000
		};

		var $httpCache = $cacheFactory.get('$http');

		//

		var createMessage = function (message) {
			if (typeof(message) == 'string')
				messageService.add(angular.extend({}, DEFAULT_MESSAGE, {
					body: message
				}));
			else
				messageService.add(angular.extend({}, DEFAULT_MESSAGE, message));
		};

		//

		$scope.tags = [];
		$scope.target = {
			container: null,
			segment: null
		};

		$scope.refreshPanel = function () {
			switch ($route.current.controller) {
				case 'VolumeView':
					$scope.prepareTags($scope.volume.tags);
					$scope.target.container = $scope.volume.top.id;
					$scope.target.segment = ',';
					$scope.enabled = true;

					$scope.enabled = $scope.tags.length > 0 || $scope.auth.isLoggedIn();
					break;

				case 'PartyView':
					$scope.prepareTags($scope.party.tags);
//					$scope.target.container = null;
//					$scope.target.segment = null;

					$scope.enabled = $scope.tags.length > 0;
					break;
			}
		};

		$scope.prepareTags = function (tags) {
			var temp = [];

			angular.forEach(tags, function (tag) {
				temp.push(tag);
			});

			$scope.tags = temp;

			$scope.sortTags();
		};

		$scope.sortTags = function () {
			$scope.tags = $scope.tags.sort(function (a, b) {
				return (a.weight > b.weight) ? -1 : (a.weight < b.weight) ? 1 : 0;
			});
		};

		$scope.retrieveTags = function () {
			switch ($route.current.controller) {
				case 'VolumeView':
					$httpCache.removeAll();

					Volume.get({
						id: $scope.volume.id,
						tags: ''
					}, function (data) {
						$scope.volume.tags = data.tags;
						$scope.refreshPanel();
					});

					break;
			}
		};

		//

		$scope.vote = function (tag, vote) {
			var tagModel = new Tag({id: tag.id});

			tagModel.$save({
				id: tag.id,
				vote: vote == -1 ? 'false' : vote == 1 ? "true" : "",
				container: $scope.target.container,
				segment: $scope.target.segment
			}, function (newTag, status, headers, config) {
				if(newTag.weight != 0)
					$scope.tags.splice($scope.tags.indexOf(tag), 1, newTag);
				else
					$scope.tags.splice($scope.tags.indexOf(tag), 1);

				switch(vote) {
					case -1:
						createMessage('Tag <strong>' + tag.id + '</strong> voted down successfully!');
						break;

					case 0:
						createMessage('Tag <strong>' + tag.id + '</strong> vote cancelled successfully!');
						break;

					case 1:
						createMessage('Tag <strong>' + tag.id + '</strong> voted up successfully!');
						break;
				}
			}, function () {
				createMessage({
					type: 'error',
					body: 'Vote for tag <strong>' + tag.id + '</strong> unsuccessful! Please refresh and try again.'
				});
			});
		};

		$scope.voteNew = function (form) {
			if (form.$invalid)
				return;

			var tagModel = new Tag({id: form.newNameVal});

			tagModel.$save({
				id: form.newNameVal,
				vote: "true",
				container: $scope.target.container,
				segment: $scope.target.segment
			}, function (newTag, status, headers, config) {
				createMessage('Tag <strong>' + form.newNameVal + '</strong> added successfully!');

				form.newNameVal = '';

				$scope.retrieveTags();
			}, function () {
				createMessage({
					type: 'error',
					body: 'Could not add tag <strong>' + tag.id + '</strong>! Please refresh and try again.'
				});
			});
		};

		//

		$scope.newNameChange = function (form) {
			if (form.newName.$pristine || form.newName.$valid)
				return disableNewNameError();

			return enableNewNameError();
		};

		$scope.newNameBlur = function (form) {
			return disableNewNameError();
		};

		//

		var enableNewNameError = function () {
			if ($scope.tagNewFormMessage) {
				messageService.enable($scope.tagNewFormMessage);
			} else {
				var message = {
					enabled: true,
					type: 'error',
					body: '<dl>' +
						'<dt>Tag Name</dt>' +
						'<dd>Must be between 3 and 32 characters.</dd>' +
						'<dd>Only letters, spaces, and dashes (-) allowed.</dd>' +
						'</dl>'
				};

				$scope.tagNewFormMessage = messageService.add(message);
			}
		};

		var disableNewNameError = function () {
			if ($scope.tagNewFormMessage)
				messageService.disable($scope.tagNewFormMessage);
		};
	}]);
});
