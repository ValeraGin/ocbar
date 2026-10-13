const colors={lime:{name:'лайм',accent:'#C3F36B',ink:'#416117'},mint:{name:'мятный',accent:'#6EE7C0',ink:'#19694E'},amber:{name:'янтарный',accent:'#FFBE70',ink:'#885218'},violet:{name:'сиреневый',accent:'#B7A4FF',ink:'#65529B'}};
document.querySelectorAll('[data-color]').forEach(button=>button.addEventListener('click',()=>{
 const key=button.dataset.color, color=colors[key];
 document.documentElement.style.setProperty('--accent',color.accent);
 document.documentElement.style.setProperty('--accent-ink',color.ink);
 document.querySelectorAll('[data-color]').forEach(item=>item.setAttribute('aria-pressed',String(item===button)));
 document.querySelectorAll('[data-icon]').forEach(img=>img.src=`icon-${key}.svg`);
 document.querySelector('#download-icon').href=`icon-${key}.svg`;
 document.querySelector('.selected').textContent=`Выбран ${color.name}. Форма свитча одинакова во всех вариантах.`;
}));
