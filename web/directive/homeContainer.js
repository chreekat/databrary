'use strict';
app.directive('homeContainer', [
  '$document', function($document) {
    return {
      restrict: 'A',
      link: function($scope, $element, $attrs) {
        //arrow on click slide to the next section
        $('.arrow-container').click(function(){
          $('html, body').animate({
                scrollTop: $(this).closest('.section').next('.section').find('h2').offset().top - 50
            }, 1000);
        });
        //nyu slider
        var streamWidth = 0;
        $('.stream li').each(function(){
          streamWidth += parseInt($(this).width(), 10);
        });
        $(".stream-nav.left").click(function () { 
            var maxWidth = streamWidth + 10 - window.innerWidth;
            var windowWidth = window.innerWidth - 80;
            $('.stream li').each(function(){
              $(this).css('margin-left', Math.min((parseInt($(this).css('margin-left'), 10) + windowWidth), 0) + 'px');
              $(this).css('margin-right', Math.max((parseInt($(this).css('margin-right'), 10) - windowWidth), 0) + 'px');
            });
        });

        $(".stream-nav.right").click(function () {
          var maxWidth = streamWidth + 10 - window.innerWidth;
          var windowWidth = window.innerWidth - 80;
          $('.stream li').each(function(){
            $(this).css('margin-left', Math.max((parseInt($(this).css('margin-left'), 10) - windowWidth), -Math.abs(maxWidth)) + 'px');
            $(this).css('margin-right', Math.min((parseInt($(this).css('margin-right'), 10) + windowWidth), maxWidth) + 'px');
          });
        });

        //stop video if the user plays another video
        $('video').each(function(){
          $(this).on('play', function(){
            $('video').not($(this)).each(function(){
              $(this).get(0).pause();
            });
          });
        });

        $('.opener').click(function(e){
          e.preventDefault();
          $(this).closest('div').next('.open-panel').slideToggle();
        });

        //testimonial carousel
        var myIndex = 0;
        var slideIndex = 1;
        var stopCarousel = false;

        function carousel() {
          if (stopCarousel === false) {
            var i;
            var x = document.getElementsByClassName("testimonial");
            for (i = 0; i < x.length; i++) {
               x[i].style.opacity = "0";
               x[i].style.zIndex = "0";
            }
            myIndex++;
            if (myIndex > x.length) {myIndex = 1}    
            x[myIndex-1].style.opacity = "1";
            x[myIndex-1].style.zIndex = "2"; 
            slideIndex = myIndex;
          
            setTimeout(carousel, 8000);
          }
        }

        carousel();

        function showDivs(n) {
          var i;
          var x = document.getElementsByClassName("testimonial");
          if (n > x.length) {slideIndex = 1} 
          if (n < 1) {slideIndex = x.length} ;
          for (i = 0; i < x.length; i++) {
              x[i].style.opacity = "0";
              x[i].style.zIndex = "0";
          }
          x[slideIndex-1].style.opacity = "1";
          x[slideIndex-1].style.zIndex = "2";
        }

        $scope.plusDivs = function(n) {
          stopCarousel = true;
          showDivs(slideIndex += n);
        }

      }
    };
  }
]);
