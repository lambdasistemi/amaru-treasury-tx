export const getPageParam = () => {
  const params = new URLSearchParams(window.location.search);
  const page = params.get("page");
  return page || "";
};

export const setPageParam = (page) => () => {
  const url = new URL(window.location);
  if (page === "") {
    url.searchParams.delete("page");
  } else {
    url.searchParams.set("page", page);
  }
  history.replaceState(null, "", url);
};
