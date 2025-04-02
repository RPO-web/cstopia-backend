// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Define hooks and UI enhancements
const UIManager = {
  // Initialize all UI enhancements
  init() {
    this.loadSortableJS();
    this.setupAlpineJS();
  },

  // Load Sortable.js dynamically
  loadSortableJS() {
    const script = document.createElement('script');
    script.src = 'https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js';
    script.onload = () => this.initializeSortables();
    document.head.appendChild(script);
  },

  // Initialize any sortable components on the page
  initializeSortables() {
    document.querySelectorAll('[phx-hook="SortablePlayers"]').forEach(el => {
      const viewName = el.getAttribute('data-phx-view');
      const view = window.liveSocket.getViewByEl(el);
      if (view && view.hooks[viewName]) {
        view.hooks[viewName].initSortable();
      }
    });
  },

  // Setup Alpine.js components when available
  setupAlpineJS() {
    const setupTooltips = () => {
      window.Alpine.data('tooltip', () => ({
        show: false,
        text: '',
        init() {
          this.text = this.$el.dataset.tooltip;
          this.show = false;
        },
        mouseEnter() { this.show = true; },
        mouseLeave() { this.show = false; }
      }));
    };

    if (typeof window.Alpine === 'undefined') {
      document.addEventListener('alpine:init', setupTooltips);
    } else {
      setupTooltips();
    }
  }
};

// LiveView hooks
let Hooks = {
  // Sortable players list hook
  SortablePlayers: {
    mounted() {
      if (typeof window.Sortable === 'undefined') return;
      this.initSortable();
    },
    
    initSortable() {
      if (!this.el || !window.Sortable) return;
      
      const leaderId = this.el.dataset.leaderId;
      const currentUserId = document.querySelector("meta[name='user-id']")?.getAttribute("content");
      
      if (currentUserId === leaderId) {
        this.sortable = new window.Sortable(this.el, {
          animation: 150,
          handle: '.drag-handle',
          ghostClass: 'bg-indigo-100',
          onEnd: (evt) => {
            const positions = {};
            Array.from(this.el.children).forEach((item, index) => {
              // Add 1 to account for leader at position 0
              positions[item.dataset.id] = index + 1;
            });
            
            this.pushEvent("update-player-positions", { positions });
          }
        });
      }
    },
    
    updated() {
      // No need to manually reorder since host is separate
    },
    
    destroyed() {
      if (this.sortable) this.sortable.destroy();
    }
  },
  
  // Auto-scrolling chat messages
  ChatScroll: {
    mounted() {
      this.scrollToBottom();
      // Initialize observer to watch for DOM changes
      this.setupMutationObserver();
      
      // Set up event handlers for LiveView events
      this.handleEvent("chat_message_deleted", ({message_id}) => {
        this.handleMessageDeleted(message_id);
      });
      
      this.handleEvent("chat_message_added", () => {
        this.scrollToBottom();
      });
    },
    
    // Set up mutation observer to detect DOM changes
    setupMutationObserver() {
      this.observer = new MutationObserver((mutations) => {
        let shouldScroll = false;
        
        // Check if messages were added or removed
        for (const mutation of mutations) {
          if (mutation.type === 'childList') {
            shouldScroll = true;
            break;
          }
        }
        
        if (shouldScroll) {
          this.scrollToBottom();
        }
      });
      
      this.observer.observe(this.el, {
        childList: true,
        subtree: true,
        attributes: false
      });
    },
    
    // Handle a message being deleted
    handleMessageDeleted(messageId) {
      const messageElement = document.getElementById(`chat-message-${messageId}`);
      if (messageElement) {
        // Add deleted styling
        messageElement.classList.add('deleted-message', 'bg-gray-100');
        
        // Find the message content and update it
        const contentElement = messageElement.querySelector('p');
        if (contentElement) {
          contentElement.textContent = "Message deleted";
          contentElement.classList.add('text-gray-500', 'italic');
          contentElement.classList.remove('text-gray-700');
        }
        
        // Remove delete button if it exists
        const deleteButton = messageElement.querySelector('button[phx-click="delete_chat_message"]');
        if (deleteButton) {
          const buttonContainer = deleteButton.closest('div');
          if (buttonContainer) {
            buttonContainer.remove();
          }
        }
        
        // Scroll to bottom if needed
        this.scrollToBottom();
      }
    },
    
    scrollToBottom() {
      // Only auto-scroll if user is already at the bottom or this is the initial load
      const isAtBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 150;
      if (isAtBottom || this.initialScroll) {
        // Small delay to ensure DOM has updated
        setTimeout(() => {
          this.el.scrollTop = this.el.scrollHeight;
        }, 10);
        this.initialScroll = false;
      }
    },
    
    updated() {
      this.scrollToBottom();
    },
    
    beforeUpdate() {
      // Store scroll position to determine if user was at bottom
      this.isAtBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 100;
      this.initialScroll = this.el.scrollTop === 0 && this.el.children.length <= 1;
    },
    
    disconnected() {
      if (this.observer) {
        this.observer.disconnect();
      }
    }
  }
};

// Initialize LiveView
const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
});

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"});
window.addEventListener("phx:page-loading-start", _info => topbar.show(300));
window.addEventListener("phx:page-loading-stop", _info => topbar.hide());

// Connect if there are any LiveViews on the page
liveSocket.connect();

// Expose liveSocket on window for web console debug logs
window.liveSocket = liveSocket;

// Initialize UI enhancements when DOM is ready
document.addEventListener('DOMContentLoaded', () => UIManager.init());

